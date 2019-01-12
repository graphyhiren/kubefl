local argo = import "kubeflow/argo/argo.libsonnet";

local params = {
  name: "argo",
  workflowControllerImage: "argoproj/workflow-controller:v2.2.0",
  uiImage: "argoproj/argoui:v2.2.0",
  executorImage: "argoproj/argoexec:v2.2.0",
  artifactRepositoryKeyPrefix: "artifacts",
  artifactRepositoryEndpoint: "minio-service.kubeflow:9000",
  artifactRepositoryBucket: "mlpipeline",
  artifactRepositoryInsecure: "true",
  artifactRepositoryAccessKeySecretName: "mlpipeline-minio-artifact",
  artifactRepositoryAccessKeySecretKey: "accesskey",
  artifactRepositorySecretKeySecretName: "mlpipeline-minio-artifact",
  artifactRepositorySecretKeySecretKey: "secretkey",
};
local env = {
  namespace: "kubeflow",
};

local instance = argo.new(env, params);

std.assertEqual(
  instance.parts.workflowCRD,
  {
    apiVersion: "apiextensions.k8s.io/v1beta1",
    kind: "CustomResourceDefinition",
    metadata: {
      name: "workflows.argoproj.io",
    },
    spec: {
      group: "argoproj.io",
      names: {
        kind: "Workflow",
        listKind: "WorkflowList",
        plural: "workflows",
        shortNames: [
          "wf",
        ],
        singular: "workflow",
      },
      scope: "Namespaced",
      version: "v1alpha1",
    },
  }
) &&

std.assertEqual(
  instance.parts.workflowController,
  {
    apiVersion: "extensions/v1beta1",
    kind: "Deployment",
    labels: {
      app: "workflow-controller",
    },
    metadata: {
      name: "workflow-controller",
      namespace: "kubeflow",
    },
    spec: {
      progressDeadlineSeconds: 600,
      replicas: 1,
      revisionHistoryLimit: 10,
      selector: {
        matchLabels: {
          app: "workflow-controller",
        },
      },
      strategy: {
        rollingUpdate: {
          maxSurge: "25%",
          maxUnavailable: "25%",
        },
        type: "RollingUpdate",
      },
      template: {
        metadata: {
          creationTimestamp: null,
          labels: {
            app: "workflow-controller",
          },
        },
        spec: {
          containers: [
            {
              args: [
                "--configmap",
                "workflow-controller-configmap",
              ],
              command: [
                "workflow-controller",
              ],
              env: [
                {
                  name: "ARGO_NAMESPACE",
                  valueFrom: {
                    fieldRef: {
                      apiVersion: "v1",
                      fieldPath: "metadata.namespace",
                    },
                  },
                },
              ],
              image: "argoproj/workflow-controller:v2.2.0",
              imagePullPolicy: "IfNotPresent",
              name: "workflow-controller",
              resources: {},
              terminationMessagePath: "/dev/termination-log",
              terminationMessagePolicy: "File",
            },
          ],
          dnsPolicy: "ClusterFirst",
          restartPolicy: "Always",
          schedulerName: "default-scheduler",
          securityContext: {},
          serviceAccount: "argo",
          serviceAccountName: "argo",
          terminationGracePeriodSeconds: 30,
        },
      },
    },
  }
) &&

std.assertEqual(
  instance.parts.argoUI,
  {
    apiVersion: "extensions/v1beta1",
    kind: "Deployment",
    metadata: {
      labels: {
        app: "argo-ui",
      },
      name: "argo-ui",
      namespace: "kubeflow",
    },
    spec: {
      progressDeadlineSeconds: 600,
      replicas: 1,
      revisionHistoryLimit: 10,
      selector: {
        matchLabels: {
          app: "argo-ui",
        },
      },
      strategy: {
        rollingUpdate: {
          maxSurge: "25%",
          maxUnavailable: "25%",
        },
        type: "RollingUpdate",
      },
      template: {
        metadata: {
          creationTimestamp: null,
          labels: {
            app: "argo-ui",
          },
        },
        spec: {
          containers: [
            {
              env: [
                {
                  name: "ARGO_NAMESPACE",
                  valueFrom: {
                    fieldRef: {
                      apiVersion: "v1",
                      fieldPath: "metadata.namespace",
                    },
                  },
                },
                {
                  name: "IN_CLUSTER",
                  value: "true",
                },
                {
                  name: "BASE_HREF",
                  value: "/argo/",
                },
              ],
              image: "argoproj/argoui:v2.2.0",
              imagePullPolicy: "IfNotPresent",
              name: "argo-ui",
              resources: {},
              terminationMessagePath: "/dev/termination-log",
              terminationMessagePolicy: "File",
            },
          ],
          dnsPolicy: "ClusterFirst",
          readinessProbe: {
            httpGet: {
              path: "/",
              port: 8001,
            },
          },
          restartPolicy: "Always",
          schedulerName: "default-scheduler",
          securityContext: {},
          serviceAccount: "argo-ui",
          serviceAccountName: "argo-ui",
          terminationGracePeriodSeconds: 30,
        },
      },
    },
  }
) &&

std.assertEqual(
  instance.parts.argUIService,
  {
    apiVersion: "v1",
    kind: "Service",
    metadata: {
      annotations: {
        "getambassador.io/config": "---\napiVersion: ambassador/v0\nkind:  Mapping\nname: argo-ui-mapping\nprefix: /argo/\nservice: argo-ui.kubeflow",
      },
      labels: {
        app: "argo-ui",
      },
      name: "argo-ui",
      namespace: "kubeflow",
    },
    spec: {
      ports: [
        {
          port: 80,
          targetPort: 8001,
        },
      ],
      selector: {
        app: "argo-ui",
      },
      sessionAffinity: "None",
      type: "NodePort",
    },
  }
) &&

std.assertEqual(
  instance.parts.workflowControllerConfigmap,
  {
    apiVersion: "v1",
    data: {
      config: "{\nexecutorImage: argoproj/argoexec:v2.2.0,\nartifactRepository:\n{\n    s3: {\n        bucket: mlpipeline,\n        keyPrefix: artifacts,\n        endpoint: minio-service.kubeflow:9000,\n        insecure: true,\n        accessKeySecret: {\n            name: mlpipeline-minio-artifact,\n            key: accesskey\n        },\n        secretKeySecret: {\n            name: mlpipeline-minio-artifact,\n            key: secretkey\n        }\n    }\n}\n}\n",
    },
    kind: "ConfigMap",
    metadata: {
      name: "workflow-controller-configmap",
      namespace: "kubeflow",
    },
  }
) &&

std.assertEqual(
  instance.parts.argoServiceAccount,
  {
    apiVersion: "v1",
    kind: "ServiceAccount",
    metadata: {
      name: "argo",
      namespace: "kubeflow",
    },
  }
) &&

std.assertEqual(
  instance.parts.argoClusterRole,
  {
    apiVersion: "rbac.authorization.k8s.io/v1beta1",
    kind: "ClusterRole",
    metadata: {
      labels: {
        app: "argo",
      },
      name: "argo",
    },
    rules: [
      {
        apiGroups: [
          "",
        ],
        resources: [
          "pods",
          "pods/exec",
        ],
        verbs: [
          "create",
          "get",
          "list",
          "watch",
          "update",
          "patch",
        ],
      },
      {
        apiGroups: [
          "",
        ],
        resources: [
          "configmaps",
        ],
        verbs: [
          "get",
          "watch",
          "list",
        ],
      },
      {
        apiGroups: [
          "",
        ],
        resources: [
          "persistentvolumeclaims",
        ],
        verbs: [
          "create",
          "delete",
        ],
      },
      {
        apiGroups: [
          "argoproj.io",
        ],
        resources: [
          "workflows",
        ],
        verbs: [
          "get",
          "list",
          "watch",
          "update",
          "patch",
        ],
      },
    ],
  }
) &&

std.assertEqual(
  instance.parts.argoClusterRoleBinding,
  {
    apiVersion: "rbac.authorization.k8s.io/v1beta1",
    kind: "ClusterRoleBinding",
    metadata: {
      labels: {
        app: "argo",
      },
      name: "argo",
    },
    roleRef: {
      apiGroup: "rbac.authorization.k8s.io",
      kind: "ClusterRole",
      name: "argo",
    },
    subjects: [
      {
        kind: "ServiceAccount",
        name: "argo",
        namespace: "kubeflow",
      },
    ],
  }
) &&

std.assertEqual(
  instance.parts.argoUIServiceAccount,
  {
    apiVersion: "v1",
    kind: "ServiceAccount",
    metadata: {
      name: "argo-ui",
      namespace: "kubeflow",
    },
  }
) &&

std.assertEqual(
  instance.parts.argoUIRole,
  {
    apiVersion: "rbac.authorization.k8s.io/v1beta1",
    kind: "ClusterRole",
    metadata: {
      labels: {
        app: "argo",
      },
      name: "argo-ui",
    },
    rules: [
      {
        apiGroups: [
          "",
        ],
        resources: [
          "pods",
          "pods/exec",
          "pods/log",
        ],
        verbs: [
          "get",
          "list",
          "watch",
        ],
      },
      {
        apiGroups: [
          "",
        ],
        resources: [
          "secrets",
        ],
        verbs: [
          "get",
        ],
      },
      {
        apiGroups: [
          "argoproj.io",
        ],
        resources: [
          "workflows",
        ],
        verbs: [
          "get",
          "list",
          "watch",
        ],
      },
    ],
  }
) &&

std.assertEqual(
  instance.parts.argUIClusterRoleBinding,
  {
    apiVersion: "rbac.authorization.k8s.io/v1beta1",
    kind: "ClusterRoleBinding",
    metadata: {
      labels: {
        app: "argo-ui",
      },
      name: "argo-ui",
    },
    roleRef: {
      apiGroup: "rbac.authorization.k8s.io",
      kind: "ClusterRole",
      name: "argo-ui",
    },
    subjects: [
      {
        kind: "ServiceAccount",
        name: "argo-ui",
        namespace: "kubeflow",
      },
    ],
  }
)
