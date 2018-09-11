{
  local k8s = import "kubeflow/core/k8s.libsonnet",
  local util = import "kubeflow/core/util.libsonnet",
  local crd = k8s.apiextensions.v1beta1.customResourceDefinition,
  local deployment = k.apps.v1beta1.deployment,
  new(_env, _params):: {
    local params = _env + _params {
      namespace: if std.objectHas(_params, "namespace") && _params.namespace != "null" then
        _params.namespace else _env.namespace,
    },

    local tfJobCrdv1alpha1 = 
      crd.new() + crd.mixin.metadata.
        withName("tfjobs.kubeflow.org").
        withNamespace(params.namespace) + crd.mixin.spec.
        withGroup("kubeflow.org").
        withVersion("v1alpha1").
        withScope("Namespaced") + crd.mixin.spec.names.
        withKind("TFJob").
        withPlural("tfjobs").
        withSingular("tfjob"),
    tfJobCrdv1alpha1:: tfJobCrdv1alpha1,

    tfJobDeployv1alpha1: {
      apiVersion: "extensions/v1beta1",
      kind: "Deployment",
      metadata: {
        name: "tf-job-operator",
        namespace: namespace,
      },
      spec: {
        replicas: 1,
        template: {
          metadata: {
            labels: {
              name: "tf-job-operator",
            },
          },
          spec: {
            containers: [
              {
                command: [
                  "/opt/mlkube/tf-operator",
                  "--controller-config-file=/etc/config/controller_config_file.yaml",
                  "--alsologtostderr",
                  "-v=1",
                ],
                env: [
                  {
                    name: "MY_POD_NAMESPACE",
                    valueFrom: {
                      fieldRef: {
                        fieldPath: "metadata.namespace",
                      },
                    },
                  },
                  {
                    name: "MY_POD_NAME",
                    valueFrom: {
                      fieldRef: {
                        fieldPath: "metadata.name",
                      },
                    },
                  },
                ],
                image: parameters.image,
                name: "tf-job-operator",
                volumeMounts: [
                  {
                    mountPath: "/etc/config",
                    name: "config-volume",
                  },
                ],
              },
            ],
            serviceAccountName: "tf-job-operator",
            volumes: [
              {
                configMap: {
                  name: "tf-job-operator-config",
                },
                name: "config-volume",
              },
            ],
          },
        },
      },
    },  // tfJobDeploy

    local tfJobCrdv1alpha2 =
      crd.new() + crd.mixin.metadata.
        withName("tfjobs.kubeflow.org").
        withNamespace(params.namespace) + crd.mixin.spec.
        withGroup("kubeflow.org").
        withVersion("v1alpha2").
        withScope("Namespaced") + crd.mixin.spec.names.
        withKind("TFJob").
        withPlural("tfjobs").
        withSingular("tfjob") + crd.mixin.spec.validation.
        withOpenApiV3SchemaMixin({
          properties: {
            spec: {
              properties: {
                tfReplicaSpecs: {
                  properties: {
                    // The validation works when the configuration contains
                    // `Worker`, `PS` or `Chief`. Otherwise it will not be validated.
                    Worker: {
                      properties: {
                        // We do not validate pod template because of
                        // https://github.com/kubernetes/kubernetes/issues/54579
                        replicas: {
                          type: "integer",
                          minimum: 1,
                        },
                      },
                    },
                    PS: {
                      properties: {
                        replicas: {
                          type: "integer",
                          minimum: 1,
                        },
                      },
                    },
                    Chief: {
                      properties: {
                        replicas: {
                          type: "integer",
                          minimum: 1,
                          maximum: 1,
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        }),  
    tfJobCrdv1alpha2:: tfJobCrdv1alpha2,


    all:: [
      self.tfJobCrdv1alpha1,
      self.tfJobCrdv1alpha2,
    ],

    list(obj=self.all):: util.list(obj),
  },
}




/*
---
{
  all(params):: [

                  $.parts(params.namespace).configMap(params.cloud, params.tfDefaultImage),
                  $.parts(params.namespace).serviceAccount,
                  $.parts(params.namespace).operatorRole(params.deploymentScope, params.deploymentNamespace),
                  $.parts(params.namespace).operatorRoleBinding(params.deploymentScope, params.deploymentNamespace),
                  $.parts(params.namespace).uiRole,
                  $.parts(params.namespace).uiRoleBinding,
                  $.parts(params.namespace).uiService(params.tfJobUiServiceType),
                  $.parts(params.namespace).uiServiceAccount,
                  $.parts(params.namespace).ui(params.tfJobImage),
                ] +

                if params.tfJobVersion == "v1alpha2" then
                  [
                    $.parts(params.namespace).crdv1alpha2,
                    $.parts(params.namespace).tfJobDeployV1Alpha2(params.tfJobImage, params.deploymentScope, params.deploymentNamespace),
                  ]
                else
                  [
                    $.parts(params.namespace).crd,
                    $.parts(params.namespace).tfJobDeploy(params.tfJobImage),
                  ],

  parts(namespace):: {


    tfJobDeployV1Alpha2(image, deploymentScope, deploymentNamespace): {
      apiVersion: "extensions/v1beta1",
      kind: "Deployment",
      metadata: {
        name: "tf-job-operator-v1alpha2",
        namespace: namespace,
      },
      spec: {
        replicas: 1,
        template: {
          metadata: {
            labels: {
              name: "tf-job-operator",
            },
          },
          spec: {
            containers: [
              {
                command: std.prune([
                  "/opt/kubeflow/tf-operator.v2",
                  "--alsologtostderr",
                  "-v=1",
                  if deploymentScope == "namespace" then ("--namespace=" + deploymentNamespace),
                ]),
                env: std.prune([
                  {
                    name: "MY_POD_NAMESPACE",
                    valueFrom: {
                      fieldRef: {
                        fieldPath: "metadata.namespace",
                      },
                    },
                  },
                  {
                    name: "MY_POD_NAME",
                    valueFrom: {
                      fieldRef: {
                        fieldPath: "metadata.name",
                      },
                    },
                  },
                  if deploymentScope == "namespace" then {
                    name: "KUBEFLOW_NAMESPACE",
                    valueFrom: {
                      fieldRef: {
                        fieldPath: "metadata.namespace",
                      },
                    },
                  },
                ]),
                image: image,
                name: "tf-job-operator",
                volumeMounts: [
                  {
                    mountPath: "/etc/config",
                    name: "config-volume",
                  },
                ],
              },
            ],
            serviceAccountName: "tf-job-operator",
            volumes: [
              {
                configMap: {
                  name: "tf-job-operator-config",
                },
                name: "config-volume",
              },
            ],
          },
        },
      },
    },  // tfJobDeploy

    // Default value for
    defaultControllerConfig(tfDefaultImage):: {
                                                grpcServerFilePath: "/opt/mlkube/grpc_tensorflow_server/grpc_tensorflow_server.py",
                                              }
                                              + if tfDefaultImage != "" && tfDefaultImage != "null" then
                                                {
                                                  tfImage: tfDefaultImage,
                                                }
                                              else
                                                {},

    aksAccelerators:: {
      accelerators: {
        "alpha.kubernetes.io/nvidia-gpu": {
          volumes: [
            {
              name: "nvidia",
              mountPath: "/usr/local/nvidia",
              hostPath: "/usr/local/nvidia",
            },
          ],
        },
      },
    },

    acsEngineAccelerators:: {
      accelerators: {
        "alpha.kubernetes.io/nvidia-gpu": {
          volumes: [
            {
              name: "nvidia",
              mountPath: "/usr/local/nvidia",
              hostPath: "/usr/local/nvidia",
            },
          ],
        },
      },
    },

    configData(cloud, tfDefaultImage):: self.defaultControllerConfig(tfDefaultImage) +
                                        if cloud == "aks" then
                                          self.aksAccelerators
                                        else if cloud == "acsengine" then
                                          self.acsEngineAccelerators
                                        else
                                          {},

    configMap(cloud, tfDefaultImage): {
      apiVersion: "v1",
      data: {
        "controller_config_file.yaml": std.manifestJson($.parts(namespace).configData(cloud, tfDefaultImage)),
      },
      kind: "ConfigMap",
      metadata: {
        name: "tf-job-operator-config",
        namespace: namespace,
      },
    },

    serviceAccount: {
      apiVersion: "v1",
      kind: "ServiceAccount",
      metadata: {
        labels: {
          app: "tf-job-operator",
        },
        name: "tf-job-operator",
        namespace: namespace,
      },
    },

    operatorRole(deploymentScope, deploymentNamespace): {
      local roleType = if deploymentScope == "cluster" then "ClusterRole" else "Role",
      apiVersion: "rbac.authorization.k8s.io/v1beta1",
      kind: roleType,
      metadata: {
        labels: {
          app: "tf-job-operator",
        },
        name: "tf-job-operator",
        [if deploymentScope == "namespace" then "namespace"]: deploymentNamespace,
      },
      rules: [
        {
          apiGroups: [
            "tensorflow.org",
            "kubeflow.org",
          ],
          resources: [
            "tfjobs",
          ],
          verbs: [
            "*",
          ],
        },
        {
          apiGroups: [
            "apiextensions.k8s.io",
          ],
          resources: [
            "customresourcedefinitions",
          ],
          verbs: [
            "*",
          ],
        },
        {
          apiGroups: [
            "storage.k8s.io",
          ],
          resources: [
            "storageclasses",
          ],
          verbs: [
            "*",
          ],
        },
        {
          apiGroups: [
            "batch",
          ],
          resources: [
            "jobs",
          ],
          verbs: [
            "*",
          ],
        },
        {
          apiGroups: [
            "",
          ],
          resources: [
            "configmaps",
            "pods",
            "services",
            "endpoints",
            "persistentvolumeclaims",
            "events",
          ],
          verbs: [
            "*",
          ],
        },
        {
          apiGroups: [
            "apps",
            "extensions",
          ],
          resources: [
            "deployments",
          ],
          verbs: [
            "*",
          ],
        },
      ],
    },  // operator-role

    operatorRoleBinding(deploymentScope, deploymentNamespace): {
      local bindingType = if deploymentScope == "cluster" then "ClusterRoleBinding" else "RoleBinding",
      local roleType = if deploymentScope == "cluster" then "ClusterRole" else "Role",
      apiVersion: "rbac.authorization.k8s.io/v1beta1",
      kind: bindingType,
      metadata: {
        labels: {
          app: "tf-job-operator",
        },
        name: "tf-job-operator",
        [if deploymentScope == "namespace" then "namespace"]: deploymentNamespace,
      },
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: roleType,
        name: "tf-job-operator",
      },
      subjects: [
        {
          kind: "ServiceAccount",
          name: "tf-job-operator",
          namespace: namespace,
        },
      ],
    },  // operator-role binding

    uiService(serviceType):: {
      apiVersion: "v1",
      kind: "Service",
      metadata: {
        name: "tf-job-dashboard",
        namespace: namespace,
        annotations: {
          "getambassador.io/config":
            std.join("\n", [
              "---",
              "apiVersion: ambassador/v0",
              "kind:  Mapping",
              "name: tfjobs-ui-mapping",
              "prefix: /tfjobs/",
              "rewrite: /tfjobs/",
              "service: tf-job-dashboard." + namespace,
            ]),
        },  //annotations
      },
      spec: {
        ports: [
          {
            port: 80,
            targetPort: 8080,
          },
        ],
        selector: {
          name: "tf-job-dashboard",
        },
        type: serviceType,
      },
    },  // uiService

    uiServiceAccount: {
      apiVersion: "v1",
      kind: "ServiceAccount",
      metadata: {
        labels: {
          app: "tf-job-dashboard",
        },
        name: "tf-job-dashboard",
        namespace: namespace,
      },
    },  // uiServiceAccount

    ui(image):: {
      apiVersion: "extensions/v1beta1",
      kind: "Deployment",
      metadata: {
        name: "tf-job-dashboard",
        namespace: namespace,
      },
      spec: {
        template: {
          metadata: {
            labels: {
              name: "tf-job-dashboard",
            },
          },
          spec: {
            containers: [
              {
                command: [
                  "/opt/tensorflow_k8s/dashboard/backend",
                ],
                env: [
                  {
                    name: "KUBEFLOW_NAMESPACE",
                    valueFrom: {
                      fieldRef: {
                        fieldPath: "metadata.namespace",
                      },
                    },
                  },
                ],
                image: image,
                name: "tf-job-dashboard",
                ports: [
                  {
                    containerPort: 8080,
                  },
                ],
              },
            ],
            serviceAccountName: "tf-job-dashboard",
          },
        },
      },
    },  // ui

    uiRole:: {
      apiVersion: "rbac.authorization.k8s.io/v1beta1",
      kind: "ClusterRole",
      metadata: {
        labels: {
          app: "tf-job-dashboard",
        },
        name: "tf-job-dashboard",
      },
      rules: [
        {
          apiGroups: [
            "tensorflow.org",
            "kubeflow.org",
          ],
          resources: [
            "tfjobs",
          ],
          verbs: [
            "*",
          ],
        },
        {
          apiGroups: [
            "apiextensions.k8s.io",
          ],
          resources: [
            "customresourcedefinitions",
          ],
          verbs: [
            "*",
          ],
        },
        {
          apiGroups: [
            "storage.k8s.io",
          ],
          resources: [
            "storageclasses",
          ],
          verbs: [
            "*",
          ],
        },
        {
          apiGroups: [
            "batch",
          ],
          resources: [
            "jobs",
          ],
          verbs: [
            "*",
          ],
        },
        {
          apiGroups: [
            "",
          ],
          resources: [
            "configmaps",
            "pods",
            "pods/log",
            "services",
            "endpoints",
            "persistentvolumeclaims",
            "events",
            "namespaces",
          ],
          verbs: [
            "*",
          ],
        },
        {
          apiGroups: [
            "apps",
            "extensions",
          ],
          resources: [
            "deployments",
          ],
          verbs: [
            "*",
          ],
        },
      ],
    },  // uiRole

    uiRoleBinding:: {
      apiVersion: "rbac.authorization.k8s.io/v1beta1",
      kind: "ClusterRoleBinding",
      metadata: {
        labels: {
          app: "tf-job-dashboard",
        },
        name: "tf-job-dashboard",
      },
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: "ClusterRole",
        name: "tf-job-dashboard",
      },
      subjects: [
        {
          kind: "ServiceAccount",
          name: "tf-job-dashboard",
          namespace: namespace,
        },
      ],
    },  // uiRoleBinding
  },
}
*/
