local assets = import "kubeflow/openmpi/assets.libsonnet";
local service = import "kubeflow/openmpi/service.libsonnet";
local util = import "kubeflow/openmpi/util.libsonnet";

local ROLE_MASTER = "master";
local ROLE_WORKER = "worker";

{
  all(params)::
    $.master(params) + $.worker(params),

  master(params)::
    [$.pod(params, ROLE_MASTER, $.masterName(params))],

  masterName(params)::
    "%s-%s" % [params.name, ROLE_MASTER],

  worker(params)::
    std.map(
      function(index) $.pod(params, ROLE_WORKER, $.workerName(params, index)),
      std.range(0, params.workers - 1)
    ),

  workerName(params, index)::
    "%s-%s-%d" % [params.name, ROLE_WORKER, index],

  pod(params, role, podName):: {
    kind: "Pod",
    apiVersion: "v1",
    metadata: {
      name: podName,
      namespace: params.namespace,
      labels: {
        app: params.name,
        role: role,
      },
    },
    spec: {
      hostname: podName,
      subdomain: service.name(params),
      restartPolicy: "Never",
      terminationGracePeriodSeconds: 30,
      dnsPolicy: "ClusterFirst",
      schedulerName: params.schedulerName,
      volumes: $.volumes(params),
      containers: $.containers(params, role),
      nodeSelector: $.nodeSelector(params, role),
    },
  },

  volumes(params):: [
    {
      name: "kubeflow-openmpi-data",
      emptyDir: {},
    },
    {
      name: "kubeflow-openmpi-secrets",
      secret: {
        secretName: params.secret,
        defaultMode: 256,  // 0400
      },
    },
    {
      name: "kubeflow-openmpi-assets",
      configMap: {
        name: assets.name(params),
        items: [
          {
            key: "init.sh",
            path: "init.sh",
            mode: 365,  // 0555
          },
          {
            key: "mca-params.conf",
            path: "mca-params.conf",
          },
          {
            key: "sshd_config",
            path: "sshd_config",
          },
          {
            key: "ssh_config",
            path: "ssh_config",
          },
          {
            key: "hostfile",
            path: "hostfile",
          },
        ],
        defaultMode: 420,  // 0644
      },
    },
  ],

  containers(params, role):: {
    local job = {
      name: "openmpi-job",
      image: params.image,
      imagePullPolicy: params.imagePullPolicy,
      resources: $.resources(params, role),
      terminationMessagePath: "/dev/termination-log",
      terminationMessagePolicy: "File",
      workingDir: "/kubeflow/openmpi/data",
      command: [
        "sh",
        params.init,
        role,
        std.toString(params.workers),
        params.exec,
        std.toString(params.initTimeout),
      ],
      ports: [
        {
          containerPort: 2022,
          protocol: "TCP",
        },
      ],
      volumeMounts: [
        {
          name: "kubeflow-openmpi-data",
          mountPath: "/kubeflow/openmpi/data",
        },
        {
          name: "kubeflow-openmpi-assets",
          mountPath: "/kubeflow/openmpi/assets",
        },
        {
          name: "kubeflow-openmpi-secrets",
          mountPath: "/kubeflow/openmpi/secrets",
        },
      ],
    },
    local controller = {
      name: "openmpi-controller",
      image: params.controllerImage,
      imagePullPolicy: "Always",
      terminationMessagePath: "/dev/termination-log",
      terminationMessagePolicy: "File",
      workingDir: "/kubeflow/openmpi/data",
      command: [
        "python",
        "/root/controller/main.py",
        "--namespace",
        params.namespace,
        "--master",
        $.masterName(params),
      ],
      volumeMounts: [
        {
          name: "kubeflow-openmpi-data",
          mountPath: "/kubeflow/openmpi/data",
        },
      ],
    },

    result:: if role == ROLE_MASTER then [job] else [job, controller],
  }.result,

  resources(params, role)::
    if role == ROLE_WORKER then {
      limits: {
        cpu: if params.cpu != "null" then params.cpu,
        memory: if params.memory != "null" then params.memory,
        "nvidia.com/gpu": if params.gpu > 0 then params.gpu,
      },
    } else {},

  nodeSelector(params, role)::
    if role == ROLE_WORKER then util.toObject(params.nodeSelector) else {},
}
