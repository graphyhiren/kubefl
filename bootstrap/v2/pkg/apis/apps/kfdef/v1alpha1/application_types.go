// Copyright 2018 The Kubeflow Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package v1alpha1

import (
	"fmt"
	"github.com/ghodss/yaml"
	"github.com/kubeflow/kubeflow/bootstrap/config"
	log "github.com/sirupsen/logrus"
	"io/ioutil"
	"k8s.io/api/v2/core/v1"
	metav1 "k8s.io/apimachinery/v2/pkg/apis/meta/v1"
	"k8s.io/apimachinery/v2/pkg/runtime"
	"os"
)

const (
	KfConfigFile = "app.yaml"
)

// KfDefSpec holds common attributes used by each platform
type KfDefSpec struct {
	config.ComponentConfig `json:",inline"`
	// TODO(jlewi): Why is AppDir a part of the spec? AppDir is currently used
	// to refer to the location on disk where all the manifests are stored.
	// But that should be treated as a local cache and not part of the spec.
	// For example, if the app is checked out on a different machine the AppDir will change.
	// AppDir. AppDir is stored in KfDefSpec because we pass a KfDef around to
	// as a way to pass the information to all the KfApps that need to know the local AppDir.
	// A better solution might be to store AppDir in KfDef.Status to better reflect its
	// ephemeral nature and match K8s semantics.
	AppDir     string `json:"appdir,omitempty"`
	Version    string `json:"version,omitempty"`
	MountLocal bool   `json:"mountLocal,omitempty"`

	// TODO(jlewi): Project, Email, IpName, Hostname, Zone and other
	// GCP specific values should be moved into GCP plugin.
	Project            string   `json:"project,omitempty"`
	Email              string   `json:"email,omitempty"`
	IpName             string   `json:"ipName,omitempty"`
	Hostname           string   `json:"hostname,omitempty"`
	Zone               string   `json:"zone,omitempty"`
	UseBasicAuth       bool     `json:"useBasicAuth"`
	SkipInitProject    bool     `json:"skipInitProject,omitempty"`
	UseIstio           bool     `json:"useIstio"`
	EnableApplications bool     `json:"enableApplications"`
	ServerVersion      string   `json:"serverVersion,omitempty"`
	DeleteStorage      bool     `json:"deleteStorage,omitempty"`
	PackageManager     string   `json:"packageManager,omitempty"`
	ManifestsRepo      string   `json:"manifestsRepo,omitempty"`
	Repos              []Repo   `json:"repos,omitempty"`
	Secrets            []Secret `json:"secrets,omitempty"`
	Plugins            []Plugin `json:"plugins,omitempty"`
}

var DefaultRegistry = RegistryConfig{
	Name: "kubeflow",
	Repo: "https://github.com/kubeflow/kubeflow.git",
	Path: "kubeflow",
}

// Plugin can be used to customize the generation and deployment of Kubeflow
// TODO(jlewi): Should Plugin contain K8s TypeMeta so that we can use ApiVersion and Kind
// to identify what it refers to?
//
// We disable deep-copy-gen because it chokes on type interface{}.
// What are the implications of that? Will we eventually need to write our own DeepCopy
// method based on marshling the object to bytes?
//
type Plugin struct {
	Name       string            `json:"name,omitempty"`

	// TODO(jlewi): Should we be using runtime.Object or runtime.RawExtension
	Spec *runtime.RawExtension `json:"spec,omitempty"`
}

// SecretRef is a reference to a secret
type SecretRef struct {
	// Name of the secret
	Name string `json:"name,omitempty"`
}

// Repo provides information about a repository providing config (e.g. kustomize packages,
// Deployment manager configs, etc...)
type Repo struct {
	// Name is a name to identify the repository.
	Name string `json:"name,omitempty"`
	// URI where repository can be obtained.
	// Can use any URI understood by go-getter:
	// https://github.com/hashicorp/go-getter/blob/master/README.md#installation-and-usage
	Uri string `json:"uri,omitempty"`

	// Root is the relative path to use as the root.
	Root string `json:"root,omitempty"`
}

// Secret provides information about secrets needed to configure Kubeflow.
// Secrets can be provided via references e.g. a URI so that they won't
// be serialized as part of the KfDefSpec which is intended to be written into source control.
type Secret struct {
	Name         string        `json:"name,omitempty"`
	SecretSource *SecretSource `json:"secretSource,omitempty"`
}

type SecretSource struct {
	LiteralSource *LiteralSource `json:"literalSource,omitempty"`
	EnvSource     *EnvSource     `json:"envSource,omitempty"`
}

type LiteralSource struct {
	Value string `json:"value,omitempty"`
}

type EnvSource struct {
	Name string `json:"Name,omitempty"`
}

// RegistryConfig is used for two purposes:
// 1. used during image build, to configure registries that should be baked into the bootstrapper docker image.
//  (See: https://github.com/kubeflow/kubeflow/blob/master/bootstrap/image_registries.yaml)
// 2. used during app create rpc call, specifies a registry to be added to an app.
//      required info for registry: Name, Repo, Version, Path
//  Additionally if any of required fields is blank we will try to map with one of
//  the registries baked into the Docker image using the name.
type RegistryConfig struct {
	Name    string `json:"name,omitempty"`
	Repo    string `json:"repo,omitempty"`
	Version string `json:"version,omitempty"`
	Path    string `json:"path,omitempty"`
	RegUri  string `json:"reguri,omitempty"`
}

type KsComponent struct {
	Name      string `json:"name,omitempty"`
	Prototype string `json:"prototype,omitempty"`
}

type KsLibrary struct {
	Name     string `json:"name"`
	Registry string `json:"registry"`
	Version  string `json:"version"`
}

type KsParameter struct {
	// nested components are referenced as "a.b.c" where "a" or "b" may be a module name
	Component string `json:"component,omitempty"`
	Name      string `json:"name,omitempty"`
	Value     string `json:"value,omitempty"`
}

type KsModule struct {
	Name       string         `json:"name"`
	Components []*KsComponent `json:"components,omitempty"`
	Modules    []*KsModule    `json:"modules,omitempty"`
}

type KsPackage struct {
	Name string `json:"name,omitempty"`
	// Registry should be the name of the registry containing the package.
	Registry string `json:"registry,omitempty"`
}

type Registry struct {
	// Name is the user defined name of a registry.
	Name string `json:"-"`
	// Protocol is the registry protocol for this registry. Currently supported
	// values are `github`, `fs`, `helm`.
	Protocol string `json:"protocol"`
	// URI is the location of the registry.
	URI string `json:"uri"`
}

type LibrarySpec struct {
	Version string
	Path    string
}

// KsRegistry corresponds to ksonnet.io/registry
// which is the registry.yaml file found in every registry.
type KsRegistry struct {
	ApiVersion string
	Kind       string
	Libraries  map[string]LibrarySpec
}

// RegistriesConfigFile corresponds to a YAML file specifying information
// about known registries.
type RegistriesConfigFile struct {
	// Registries provides information about known registries.
	Registries []*RegistryConfig
}

type AppConfig struct {
	Registries []*RegistryConfig `json:"registries,omitempty"`
	Packages   []KsPackage       `json:"packages,omitempty"`
	Components []KsComponent     `json:"components,omitempty"`
	Parameters []KsParameter     `json:"parameters,omitempty"`
	// Parameters to apply when creating the ksonnet components
	ApplyParameters []KsParameter `json:"applyParameters,omitempty"`
}

// KfDefStatus defines the observed state of KfDef
type KfDefStatus struct {
	Conditions []KfDefCondition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type" protobuf:"bytes,6,rep,name=conditions"`
	// ReposCache is used to cache information about local caching of the URIs.
	ReposCache map[string]RepoCache `json:"reposCache,omitempty"`
}

type RepoCache struct {
	LocalPath string `json:"localPath,string"`
}

type KfDefConditionType string

type KfDefCondition struct {
	// Type of deployment condition.
	Type KfDefConditionType `json:"type" protobuf:"bytes,1,opt,name=type,casttype=KfDefConditionType"`
	// Status of the condition, one of True, False, Unknown.
	Status v1.ConditionStatus `json:"status" protobuf:"bytes,2,opt,name=status,casttype=k8s.io/api/v2/core/v1.ConditionStatus"`
	// The last time this condition was updated.
	LastUpdateTime metav1.Time `json:"lastUpdateTime,omitempty" protobuf:"bytes,6,opt,name=lastUpdateTime"`
	// Last time the condition transitioned from one status to another.
	LastTransitionTime metav1.Time `json:"lastTransitionTime,omitempty" protobuf:"bytes,7,opt,name=lastTransitionTime"`
	// The reason for the condition's last transition.
	Reason string `json:"reason,omitempty" protobuf:"bytes,4,opt,name=reason"`
	// A human readable message indicating details about the transition.
	Message string `json:"message,omitempty" protobuf:"bytes,5,opt,name=message"`
}

// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/v2/pkg/runtime.Object

// KfDef is the Schema for the applications API
// +k8s:openapi-gen=true
type KfDef struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   KfDefSpec   `json:"spec,omitempty"`
	Status KfDefStatus `json:"status,omitempty"`
}

// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/v2/pkg/runtime.Object

// KfDefList contains a list of KfDef
type KfDefList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []KfDef `json:"items"`
}

// GetDefaultRegistry return reference of a newly copied Default Registry
func GetDefaultRegistry() *RegistryConfig {
	newReg := DefaultRegistry
	return &newReg
}

// GetSecret returns the specified secret or an error if the secret isn't specified.
func (d *KfDef) GetSecret(name string) (string, error) {
	for _, s := range d.Spec.Secrets {
		if s.Name != name {
			continue
		}
		if s.SecretSource.LiteralSource != nil {
			return s.SecretSource.LiteralSource.Value, nil
		}
		if s.SecretSource.EnvSource != nil {
			return os.Getenv(s.SecretSource.EnvSource.Name), nil
		}

		return "", fmt.Errorf("No secret source provided for secret %v", name)
	}
	return "", fmt.Errorf("No secret in KfDef named %v", name)
}

// SetSecret sets the specified secret; if a secret with the given name already exists it is overwritten.
func (d *KfDef) SetSecret(newSecret Secret) {
	for i, s := range d.Spec.Secrets {
		if s.Name == newSecret.Name {
			d.Spec.Secrets[i] = newSecret
			return
		}
	}

	d.Spec.Secrets = append(d.Spec.Secrets, newSecret)
}

// GetPluginSpec will try to unmarshal the spec for the specified plugin to the supplied
// interface. Returns an error if the plugin isn't defined or if there is a problem
// unmarshaling it.
func (d *KfDef) GetPluginSpec(pluginName string, s interface{}) error {
	for _, p := range d.Spec.Plugins {
		if p.Name != pluginName {
			continue
		}

		// To deserialize it to a specific type we need to first serialize it to bytes
		// and then unserialize it.
		specBytes, err := yaml.Marshal(p.Spec)

		if err != nil {
			log.Errorf("Could not marshal plugin %v args; error %v", pluginName, err)
			return err
		}

		err = yaml.Unmarshal(specBytes, s)

		if err != nil {
			log.Errorf("Could not unmarshal plugin %v to the provided type; error %v", pluginName, err)
		}
		return nil
	}

	return NewPluginNotFound(pluginName)
}

// GetPluginSpec will try to unmarshal the spec for the specified plugin to the supplied
// interface. Returns an error if the plugin isn't defined or if there is a problem
// unmarshaling it
//
// TODO(jlewi): The reason this function exists is because for types like Gcp in gcp.go
// we embed KfDef into the Gcp struct so its not actually a type KfDef. In the future
// we will probably refactor KfApp into an appropriate plugin in type an stop embedding
// KfDef in it.
func (s *KfDefSpec) GetPluginSpec(pluginName string, pluginSpec interface{}) error {
	d := &KfDef{
		Spec: *s,
	}
	return d.GetPluginSpec(pluginName, pluginSpec)
}

// SetPluginSpec sets the requested parameter. The plugin is added if it doesn't already exist.
func (d *KfDef) SetPluginSpec(pluginName string, spec interface{}) error {
	// Convert spec to RawExtension

	r := &runtime.RawExtension{}

	// To deserialize it to a specific type we need to first serialize it to bytes
	// and then unserialize it.
	specBytes, err := yaml.Marshal(spec)

	if err != nil {
		log.Errorf("Could not marshal spec; error %v", err)
		return err
	}

	err = yaml.Unmarshal(specBytes, r)

	if err != nil {
		log.Errorf("Could not unmarshal plugin to RawExtension; error %v", err)
	}

	index := -1

	for i, p := range d.Spec.Plugins {
		if p.Name == pluginName {
			index = i
			break
		}
	}

	if index == -1 {
		// Plugin in doesn't exist so add it
		log.Infof("Adding plugin %v", pluginName)

		d.Spec.Plugins = append(d.Spec.Plugins, Plugin{
			Name: pluginName,
		})

		index = len(d.Spec.Plugins) - 1
	}

	d.Spec.Plugins[index].Spec = r

	return nil
}

// WriteToFile write the KfDef to a file.
// WriteToFile will strip out any literal secrets before writing it
func (d *KfDef) WriteToFile(path string) error {

	stripped := *d

	secrets := make([]Secret, 0)

	for _, s := range stripped.Spec.Secrets {
		if s.SecretSource.LiteralSource != nil {
			log.Warnf("Stripping literal secret %v from KfDef before serializing it", s.Name)
			continue
		}
		secrets = append(secrets, s)
	}

	stripped.Spec.Secrets = secrets

	// Rewrite app.yaml
	buf, bufErr := yaml.Marshal(stripped)
	if bufErr != nil {
		log.Errorf("Error marshaling kfdev; %v", bufErr)
		return bufErr
	}
	log.Infof("Writing stripped KfDef to %v", path)
	return ioutil.WriteFile(path, buf, 0644)
}

type PluginNotFound struct {
	Name string
}

func (e *PluginNotFound) Error() string {
	return fmt.Sprintf("Missing plugin %v", e.Name)
}

func NewPluginNotFound(n string) *PluginNotFound {
	return &PluginNotFound{
		Name: n,
	}
}

func IsPluginNotFound(e error) bool {
	_, ok := e.(*PluginNotFound)
	return ok
}
