/*
Copyright The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package ksapp

import (
	"bufio"
	"bytes"
	"fmt"
	"github.com/cenkalti/backoff"
	"github.com/ksonnet/ksonnet/pkg/actions"
	"github.com/ksonnet/ksonnet/pkg/app"
	"github.com/ksonnet/ksonnet/pkg/client"
	"github.com/ksonnet/ksonnet/pkg/component"
	kftypes "github.com/kubeflow/kubeflow/bootstrap/pkg/apis/apps/v1alpha1"
	log "github.com/sirupsen/logrus"
	"github.com/spf13/afero"
	"github.com/spf13/viper"
	"io"
	"k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	"math/rand"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"text/template"
	"time"
)

// KsApp implements the KfApp Interface
type KsApp struct {
	AppName string
	// AppDir is the directory where apps should be stored.
	AppDir string
	// ksonnet root name
	KsName string
	// ksonnet env name
	KsEnvName string
	CfgFile   *viper.Viper
	Fs        afero.Fs
	KApp      app.App
	KsApp     kftypes.KsApp
}

var KsAppTemplate = string(`
apiVersion: {{.APIVersion}}
kind: {{.Kind}}
metadata: 
  name: {{.ObjectMeta.Name}}
  namespace: {{.ObjectMeta.Namespace}}
spec:
  platform: {{.Spec.Platform}}
  components: {{.Spec.Components}}
  app:
    registries:
{{range $registry := .Spec.App.Registries }}
      - name: {{$registry.Name}}
        repo: {{$registry.Repo}}
        version: {{$registry.Version}}
        path: {{$registry.Path}}
        RegUri: {{$registry.RegUri}}
{{end}}
    packages:
{{range $package := .Spec.App.Packages }}
      - name: {{$package.Name}}
        registry: {{$package.Registry}}
{{end}}
    components:
{{range $component := .Spec.App.Components }}
      - name: {{$component.Name}}
        prototype: {{$component.Prototype}}
{{end}}
    parameters:
{{range $parameter := .Spec.App.Parameters }}
      - component: {{$parameter.Component}}
        name: {{$parameter.Name}}
        value: {{$parameter.Value}}
{{end}}
`)

func KubeConfigPath() string {
	kubeconfigEnv := os.Getenv("KUBECONFIG")
	if kubeconfigEnv == "" {
		home := os.Getenv("HOMEDRIVE") + os.Getenv("HOMEPATH")
		if home == "" {
			for _, h := range []string{"HOME", "USERPROFILE"} {
				if home = os.Getenv(h); home != "" {
					break
				}
			}
		}
		kubeconfigPath := filepath.Join(home, ".kube", "config")
		return kubeconfigPath
	}
	return kubeconfigEnv
}

// BuildOutOfClusterConfig returns k8s config
func BuildOutOfClusterConfig() (*rest.Config, error) {
	loadingRules := clientcmd.NewDefaultClientConfigLoadingRules()
	loadingRules.ExplicitPath = KubeConfigPath()
	config, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		loadingRules, &clientcmd.ConfigOverrides{}).ClientConfig()
	if err != nil {
		return nil, err
	}
	return config, nil
}

func ServerVersion() (host string, version string, err error) {
	restApi, err := BuildOutOfClusterConfig()
	if err != nil {
		return "", "", fmt.Errorf("couldn't build out-of-cluster config. Error: %v", err)
	}
	clnt, clntErr := kubernetes.NewForConfig(restApi)
	if clntErr != nil {
		return "", "", fmt.Errorf("couldn't get clientset. Error: %v", err)
	}
	serverVersion, serverVersionErr := clnt.ServerVersion()
	if serverVersionErr != nil {
		return "", "", fmt.Errorf("couldn't get server version info. Error: %v", serverVersionErr)
	}
	re := regexp.MustCompile("^v[0-9]+.[0-9]+.[0-9]+")
	version = re.FindString(serverVersion.String())
	return restApi.Host, "version:" + version, nil
}

func GetClientConfig() (*clientcmdapi.Config, error) {
	kubeconfig := KubeConfigPath()
	config, configErr := clientcmd.LoadFromFile(kubeconfig)
	if configErr != nil {
		return nil, fmt.Errorf("could not load config Error: %v", configErr)

	}
	return config, nil
}

// GetClientOutOfCluster returns a k8s clientset to the request from outside of cluster
func GetClientOutOfCluster() (kubernetes.Interface, error) {
	config, err := BuildOutOfClusterConfig()
	if err != nil {
		log.Fatalf("Can not get kubernetes config: %v", err)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("Can not get kubernetes client: %v", err)
	}

	return clientset, nil
}

// capture replaces os.Stdout with a writer that buffers any data written
// to os.Stdout. Call the returned function to cleanup and get the data
// as a string.
func capture() func() (string, error) {
	r, w, err := os.Pipe()
	if err != nil {
		panic(err)
	}

	done := make(chan error, 1)

	save := os.Stdout
	os.Stdout = w

	var buf strings.Builder

	go func() {
		_, err := io.Copy(&buf, r)
		_ = r.Close()
		done <- err
	}()

	return func() (string, error) {
		os.Stdout = save
		_ = w.Close()
		err := <-done
		return buf.String(), err
	}
}

func writeConfigFile(cfg *viper.Viper, appName string, AppDir string) error {
	tmpl, tmplErr := template.New(kftypes.KfConfigFile).Parse(KsAppTemplate)
	if tmplErr != nil {
		return tmplErr
	}
	namespace := os.Getenv("K8S_NAMESPACE")
	if namespace == "" {
		namespace = kftypes.DefaultNamespace
	}
	kubeflowRepo := os.Getenv("DEFAULT_KUBEFLOW_REPO")
	if kubeflowRepo == "" {
		kubeflowRepo = kftypes.DefaultKfRepo
	}
	re := regexp.MustCompile(`(^\$GOPATH)(.*$)`)
	goPathVar := os.Getenv("GOPATH")
	if goPathVar != "" {
		kubeflowRepo = re.ReplaceAllString(kubeflowRepo, goPathVar+`$2`)
	}
	log.Infof("kubeflowRepo %v", kubeflowRepo)
	ksApp := kftypes.KsApp{
		TypeMeta: metav1.TypeMeta{
			Kind:       "KsApp",
			APIVersion: "apps.kubeflow.org/v1alpha1",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      appName,
			Namespace: namespace,
		},
		Spec: kftypes.KsAppSpec{
			Platform:   "none",
			Components: []string{"all"},
			App: kftypes.AppConfig{
				Registries: []*kftypes.RegistryConfig{
					{
						Name:    "kubeflow",
						Repo:    "https://github.com/kubeflow/kubeflow.git",
						Version: "0.4",
						Path:    "kubeflow",
						RegUri:  kubeflowRepo,
					},
				},
				Packages: []kftypes.KsPackage{
					{
						Name:     "argo",
						Registry: "kubeflow",
					},
					{
						Name:     "pipeline",
						Registry: "kubeflow",
					},
					{
						Name:     "common",
						Registry: "kubeflow",
					},
					{
						Name:     "examples",
						Registry: "kubeflow",
					},
					{
						Name:     "jupyter",
						Registry: "kubeflow",
					},
					{
						Name:     "katib",
						Registry: "kubeflow",
					},
					{
						Name:     "mpi-job",
						Registry: "kubeflow",
					},
					{
						Name:     "pytorch-job",
						Registry: "kubeflow",
					},
					{
						Name:     "seldon",
						Registry: "kubeflow",
					},
					{
						Name:     "tf-serving",
						Registry: "kubeflow",
					},
					{
						Name:     "openvino",
						Registry: "kubeflow",
					},
					{
						Name:     "tensorboard",
						Registry: "kubeflow",
					},
					{
						Name:     "tf-training",
						Registry: "kubeflow",
					},
					{
						Name:     "metacontroller",
						Registry: "kubeflow",
					},
					{
						Name:     "profiles",
						Registry: "kubeflow",
					},
					{
						Name:     "application",
						Registry: "kubeflow",
					},
					{
						Name:     "modeldb",
						Registry: "kubeflow",
					},
				},
				Components: []kftypes.KsComponent{},
				Parameters: []kftypes.KsParameter{
					{
						Component: "spartakus",
						Name:      "usageId",
						Value:     fmt.Sprintf("%08d", 10000000+rand.Intn(90000000)),
					},
					{
						Component: "spartakus",
						Name:      "reportUsage",
						Value:     "true",
					},
				},
			},
		},
	}

	var buf bytes.Buffer
	execErr := tmpl.Execute(&buf, ksApp)
	if execErr != nil {
		return execErr
	}
	errDefaultConfig := cfg.ReadConfig(bytes.NewBuffer(buf.Bytes()))
	if errDefaultConfig != nil {
		return errDefaultConfig
	}
	CfgFile := filepath.Join(AppDir, kftypes.KfConfigFile)
	CfgFileErr := cfg.WriteConfigAs(CfgFile)
	if CfgFileErr != nil {
		return CfgFileErr
	}
	return nil
}

func (ksApp *KsApp) Apply() error {
	host, _, err := ServerVersion()
	if err != nil {
		return fmt.Errorf("couldn't get server version: %v", err)
	}
	cli, cliErr := GetClientOutOfCluster()
	if cliErr != nil {
		return fmt.Errorf("couldn't create client Error: %v", cliErr)
	}
	envSetErr := ksApp.EnvSet(kftypes.KsEnvName, host)
	if envSetErr != nil {
		return fmt.Errorf("couldn't create ksonnet env %v Error: %v", kftypes.KsEnvName, envSetErr)
	}
	//ks param set application name ${DEPLOYMENT_NAME}
	name := ksApp.KsApp.Name
	paramSetErr := ksApp.ParamSet("application", "name", name)
	if paramSetErr != nil {
		return fmt.Errorf("couldn't set application component's name to %v Error: %v", name, paramSetErr)
	}
	namespace := os.Getenv("K8S_NAMESPACE")
	if namespace == "" {
		namespace = kftypes.DefaultNamespace
	}
	_, nsMissingErr := cli.CoreV1().Namespaces().Get(namespace, metav1.GetOptions{})
	if nsMissingErr != nil {
		nsSpec := &v1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: namespace}}
		_, nsErr := cli.CoreV1().Namespaces().Create(nsSpec)
		if nsErr != nil {
			return fmt.Errorf("couldn't create namespace %v Error: %v", namespace, nsErr)
		}
	}
	clientConfig, clientConfigErr := GetClientConfig()
	if clientConfigErr != nil {
		return fmt.Errorf("couldn't load client config Error: %v", clientConfigErr)
	}
	components := []string{"metacontroller"}
	applyErr := ksApp.ApplyComponent(components, clientConfig)
	if applyErr != nil {
		return fmt.Errorf("couldn't apply metacontroller Error: %v", applyErr)
	}
	components = []string{"application"}
	applyErr = ksApp.ApplyComponent(components, clientConfig)
	if applyErr != nil {
		return fmt.Errorf("couldn't apply application Error: %v", applyErr)
	}
	return nil
}

func (ksApp *KsApp) ApplyComponent(components []string, cfg *clientcmdapi.Config) error {
	applyOptions := map[string]interface{}{
		actions.OptionApp: ksApp.KApp,
		actions.OptionClientConfig: &client.Config{
			Overrides: &clientcmd.ConfigOverrides{},
			Config:    clientcmd.NewDefaultClientConfig(*cfg, &clientcmd.ConfigOverrides{}),
		},
		actions.OptionComponentNames: components,
		actions.OptionCreate:         true,
		actions.OptionDryRun:         false,
		actions.OptionEnvName:        "default",
		actions.OptionGcTag:          "gc-tag",
		actions.OptionSkipGc:         true,
	}
	bo := backoff.WithMaxRetries(backoff.NewConstantBackOff(5*time.Second), 6)
	doneApply := make(map[string]bool)
	err := backoff.Retry(func() error {
		for _, comp := range components {
			if _, ok := doneApply[comp]; ok {
				continue
			}
			applyOptions[actions.OptionComponentNames] = []string{comp}
			err := actions.RunApply(applyOptions)
			if err == nil {
				log.Infof("Component %v apply succeeded", comp)
				doneApply[comp] = true
			} else {
				log.Errorf("(Will retry) Component %v apply failed; Error: %v", comp, err)
			}
		}
		if len(doneApply) == len(components) {
			return nil
		}
		return fmt.Errorf("%v failed components in last try", len(components)-len(doneApply))
	}, bo)
	if err != nil {
		log.Errorf("Components apply failed; Error: %v", err)
	} else {
		log.Infof("All components apply succeeded")
	}
	return err

}

func (ksApp *KsApp) ComponentAdd(component kftypes.KsComponent, args []string) error {
	componentPath := filepath.Join(ksApp.KsRoot(), "components", component.Name+".jsonnet")
	componentArgs := make([]string, 0)
	componentArgs = append(componentArgs, component.Prototype)
	componentArgs = append(componentArgs, component.Name)
	if args != nil && len(args) > 0 {
		componentArgs = append(componentArgs, args[0:]...)
	}
	if exists, _ := afero.Exists(ksApp.Fs, componentPath); !exists {
		log.Infof("Creating Component: %v ...", component.Name)
		err := actions.RunPrototypeUse(map[string]interface{}{
			actions.OptionAppRoot:   ksApp.KsRoot(),
			actions.OptionArguments: componentArgs,
		})
		if err != nil {
			return fmt.Errorf("there was a problem adding component %v: %v", component.Name, err)
		}
	} else {
		log.Infof("Component %v already exists", component.Name)
	}
	return nil
}

func (ksApp *KsApp) Components() (map[string]*kftypes.KsComponent, error) {
	moduleName := "/"

	topModule := component.NewModule(ksApp.KApp, moduleName)
	components, err := topModule.Components()
	if err != nil {
		return nil, fmt.Errorf("there was a problem getting the Components %v. Error: %v", ksApp.AppName, err)
	}
	comps := make(map[string]*kftypes.KsComponent)
	for _, comp := range components {
		name := comp.Name(false)
		comps[name] = &kftypes.KsComponent{
			Name:      name,
			Prototype: name,
		}
	}
	return comps, nil
}

func (ksApp *KsApp) Delete() error {
	return nil
}

func (ksApp *KsApp) Generate() error {
	host, k8sSpec, err := ServerVersion()
	if err != nil {
		return fmt.Errorf("couldn't get server version: %v", err)
	}
	namespace := os.Getenv("K8S_NAMESPACE")
	writeConfigErr := writeConfigFile(ksApp.CfgFile, ksApp.AppName, ksApp.AppDir)
	if writeConfigErr != nil {
		return fmt.Errorf("couldn't write config file app.yaml in %v Error %v", ksApp.AppDir, writeConfigErr)
	}
	initErr := ksApp.InitKs("default", k8sSpec, host, namespace)
	if initErr != nil {
		return fmt.Errorf("couldn't initialize KfApi: %v", initErr)
	}
	for _, registry := range ksApp.KsApp.Spec.App.Registries {
		registryAddErr := ksApp.RegistryAdd(registry)
		if registryAddErr != nil {
			return fmt.Errorf("couldn't add registry %v. Error: %v", registry.Name, registryAddErr)
		}
	}
	for _, pkg := range ksApp.KsApp.Spec.App.Packages {
		packageAddErr := ksApp.PkgInstall(pkg)
		if packageAddErr != nil {
			return fmt.Errorf("couldn't add package %v. Error: %v", pkg.Name, packageAddErr)
		}
	}
	componentArray := ksApp.KsApp.Spec.Components
	if len(componentArray) == 1 && componentArray[0] == "all" {
		componentArray = []string{
			"ambassador",
			"application",
			"argo",
			"centraldashboard",
			"jupyter",
			"katib",
			"metacontroller",
			"notebooks",
			"openvino",
			"pipeline",
			"profiles",
			"pytorch-operator",
			"spartakus",
			"tensorboard",
			"tf-job-operator",
		}
	}
	for _, compName := range componentArray {
		comp := kftypes.KsComponent{
			Name:      compName,
			Prototype: compName,
		}
		componentAddErr := ksApp.ComponentAdd(comp, []string{})
		if componentAddErr != nil {
			return fmt.Errorf("couldn't add comp %v. Error: %v", comp.Name, componentAddErr)
		}
	}
	for _, parameter := range ksApp.KsApp.Spec.App.Parameters {
		parameterSetErr := ksApp.ParamSet(parameter.Component, parameter.Name, parameter.Value)
		if parameterSetErr != nil {
			return fmt.Errorf("couldn't set %v for comp %v. Error: %v",
				parameter.Name, parameter.Component, parameterSetErr)
		}
	}
	return nil
}

func (ksApp *KsApp) Init(appName string) error {
	//TODO must be checked eg `kfctl init kf_app` results in
	// metadata.name: Invalid value:
	// "kf_app-controller": a DNS-1123 subdomain must consist of lower case alphanumeric characters, '-' or '.',
	// and must start and end with an alphanumeric character (e.g. 'example.com', regex used for validation is
	// '[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*')
	dir, err := os.Getwd()
	if err != nil {
		log.Fatal(err)
	}
	AppDir := path.Join(dir, appName)
	log.Infof("AppDir %v", AppDir)
	err = os.Mkdir(AppDir, os.ModePerm)
	if err != nil {
		return fmt.Errorf("cannot create directory %v", AppDir)
	}
	fs := afero.NewOsFs()
	CfgFilePath := filepath.Join(AppDir, kftypes.KfConfigFile)
	_, AppDirErr := fs.Stat(CfgFilePath)
	if AppDirErr == nil {
		return fmt.Errorf("config file %v already exists in %v", kftypes.KfConfigFile, AppDir)
	}
	createConfigErr := writeConfigFile(ksApp.CfgFile, appName, AppDir)
	if createConfigErr != nil {
		return fmt.Errorf("cannot create config file app.yaml in %v", AppDir)
	}
	return nil
}

func (ksApp *KsApp) InitKs(envName string, k8sSpecFlag string, host string, namespace string) error {
	newRoot := path.Join(ksApp.AppDir, ksApp.KsName)
	ksApp.KsEnvName = envName
	options := map[string]interface{}{
		actions.OptionFs:                    ksApp.Fs,
		actions.OptionName:                  ksApp.KsName,
		actions.OptionEnvName:               ksApp.KsEnvName,
		actions.OptionNewRoot:               newRoot,
		actions.OptionServer:                host,
		actions.OptionSpecFlag:              k8sSpecFlag,
		actions.OptionNamespace:             namespace,
		actions.OptionSkipDefaultRegistries: true,
	}
	err := actions.RunInit(options)
	if err != nil {
		return fmt.Errorf("there was a problem initializing the app: %v", err)
	}
	log.Infof("Successfully initialized the app %v.", ksApp.AppName)

	return nil
}

func (ksApp *KsApp) EnvSet(envName string, host string) error {
	ksApp.KsEnvName = envName
	err := actions.RunEnvSet(map[string]interface{}{
		actions.OptionAppRoot: ksApp.KsRoot(),
		actions.OptionEnvName: ksApp.KsEnvName,
		actions.OptionServer:  host,
	})
	if err != nil {
		return fmt.Errorf("There was a problem setting ksonnet env: %v", err)
	}
	return nil
}

func (ksApp *KsApp) KsRoot() string {
	root := path.Join(ksApp.AppDir, ksApp.KsName)
	return root
}

func (ksApp *KsApp) Libraries() (map[string]*kftypes.KsLibrary, error) {
	libs, err := ksApp.KApp.Libraries()
	if err != nil {
		return nil, fmt.Errorf("there was a problem getting the libraries %v. Error: %v", ksApp.AppName, err)
	}

	libraries := make(map[string]*kftypes.KsLibrary)
	for k, v := range libs {
		libraries[k] = &kftypes.KsLibrary{
			Name:     v.Name,
			Registry: v.Registry,
			Version:  v.Version,
		}
	}
	return libraries, nil
}

func (ksApp *KsApp) Registries() (map[string]*kftypes.Registry, error) {
	regs, err := ksApp.KApp.Registries()
	if err != nil {
		return nil, fmt.Errorf("There was a problem getting the Registries %v. Error: %v", ksApp.AppName, err)
	}
	registries := make(map[string]*kftypes.Registry)
	for k, v := range regs {
		registries[k] = &kftypes.Registry{
			Name:     v.Name,
			Protocol: v.Protocol,
			URI:      v.URI,
		}
	}

	return registries, nil
}

func (ksApp *KsApp) Root() string {
	return ksApp.AppDir
}

func (ksApp *KsApp) ParamSet(component string, name string, value string) error {
	err := actions.RunParamSet(map[string]interface{}{
		actions.OptionAppRoot: ksApp.KsRoot(),
		actions.OptionName:    component,
		actions.OptionPath:    name,
		actions.OptionValue:   value,
	})
	if err != nil {
		return fmt.Errorf("Error when setting Parameters %v for Component %v: %v", name, component, err)
	}
	return nil
}

func (ksApp *KsApp) PkgInstall(pkg kftypes.KsPackage) error {
	root := ksApp.KsRoot()
	err := actions.RunPkgInstall(map[string]interface{}{
		actions.OptionAppRoot: root,
		actions.OptionPkgName: pkg.Registry + "/" + pkg.Name,
		actions.OptionName:    pkg.Name,
		actions.OptionForce:   false,
	})
	if err != nil {
		return fmt.Errorf("there was a problem installing package %v: %v", pkg.Name, err)
	}
	return nil
}

func (ksApp *KsApp) PrototypeUse(m map[string]interface{}) error {
	return nil
}

func (ksApp *KsApp) RegistryAdd(registry *kftypes.RegistryConfig) error {
	log.Infof("App %v add registry %v URI %v", ksApp.AppName, registry.Name, registry.RegUri)
	root := ksApp.KsRoot()
	options := map[string]interface{}{
		actions.OptionAppRoot:  root,
		actions.OptionName:     registry.Name,
		actions.OptionURI:      registry.RegUri,
		actions.OptionPath:     registry.Path,
		actions.OptionVersion:  registry.Version,
		actions.OptionOverride: false,
	}
	err := actions.RunRegistryAdd(options)
	if err != nil {
		return fmt.Errorf("there was a problem adding registry %v: %v", registry.Name, err)
	}
	return nil
}

func (ksApp *KsApp) Show(components []string) error {
	done := capture()
	err := actions.RunShow(map[string]interface{}{
		actions.OptionApp:            ksApp.KApp,
		actions.OptionComponentNames: components,
		actions.OptionEnvName:        ksApp.KsEnvName,
		actions.OptionFormat:         "yaml",
	})
	if err != nil {
		return fmt.Errorf("there was a problem showing components %v: %v", components, err)
	}
	capturedOutput, capturedOutputErr := done()
	if capturedOutputErr != nil {
		return fmt.Errorf("there was a problem capturing the output: %v", capturedOutput)
	}
	outputFileName := filepath.Join(ksApp.KsRoot(), ksApp.KsEnvName+".yaml")
	outputFile, outputFileErr := os.Create(outputFileName)
	if outputFileErr != nil {
		return fmt.Errorf("there was a problem creating output file %v: %v", outputFileName, outputFileErr)
	}
	defer outputFile.Close()
	writer := bufio.NewWriter(outputFile)
	_, writerErr := writer.WriteString(capturedOutput)
	if writerErr != nil {
		return fmt.Errorf("there was a problem writing to %v: %v", outputFileName, writerErr)
	}
	flushErr := writer.Flush()
	if flushErr != nil {
		return fmt.Errorf("there was a problem flushing file %v: %v", outputFileName, flushErr)
	}

	return nil
}
