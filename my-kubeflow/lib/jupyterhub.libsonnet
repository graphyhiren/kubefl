
{  
  // TODO(https://github.com/ksonnet/ksonnet/issues/222): Taking namespace as an argument is a work around for the fact that ksonnet
  // doesn't support automatically piping in the namespace from the environment to prototypes.
  parts(namespace):: {

    // TODO(jlewi): We should make the default Docker image configurable
    // TODO(jlewi): We should make whether we use PVC configurable.
  	local baseKubeConfigSpawner = @"import json
import os
from kubespawner.spawner import KubeSpawner
from oauthenticator.github import GitHubOAuthenticator

class KubeFormSpawner(KubeSpawner):
  def _options_form_default(self):
    return '''
    <label for='image'>Image</label>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
    <input name='image' placeholder='repo/image:tag'></input>
    <br/><br/>

    <label for='cpu_guarantee'>CPU</label>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
    <input name='cpu_guarantee' placeholder='200m, 1.0, 2.5, etc'></input>
    <br/><br/>

    <label for='mem_guarantee'>Memory</label>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
    <input name='mem_guarantee' placeholder='100Mi, 1.5Gi'></input>
    <br/><br/>

    <label for='extra_resource_limits'>Extra Resource Limits</label>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
    <input name='extra_resource_limits' placeholder='{'nvidia.com/gpu': '3'}'></input>
    <br/><br/>
    '''

  def options_from_form(self, formdata):
    options = {}
    options['image'] = formdata.get('image', [''])[0].strip()
    options['cpu_guarantee'] = formdata.get('cpu_guarantee', [''])[0].strip()
    options['mem_guarantee'] = formdata.get('mem_guarantee', [''])[0].strip()
    options['extra_resource_limits'] = formdata.get('extra_resource_limits', [''])[0].strip()
    return options

  @property
  def singleuser_image_spec(self):
    image = 'gcr.io/kubeflow/tensorflow-notebook-cpu'
    if self.user_options.get('image'):
      image = self.user_options['image']
    return image

  @property
  def cpu_guarantee(self):
    cpu = '500m'
    if self.user_options.get('cpu_guarantee'):
      cpu = self.user_options['cpu_guarantee']
    return cpu

  @property
  def mem_guarantee(self):
    mem = '1Gi'
    if self.user_options.get('mem_guarantee'):
      mem = self.user_options['mem_guarantee']
    return mem

  @property
  def extra_resource_limits(self):
    extra = ''
    if self.user_options.get('extra_resource_limits'):
      extra = json.loads(self.user_options['extra_resource_limits'])
    return extra

###################################################
### JupyterHub Options
###################################################
c.JupyterHub.ip = '0.0.0.0'
c.JupyterHub.hub_ip = '0.0.0.0'
# Don't try to cleanup servers on exit - since in general for k8s, we want
# the hub to be able to restart without losing user containers
c.JupyterHub.cleanup_servers = False
###################################################

###################################################
### Spawner Options
###################################################
c.JupyterHub.spawner_class = KubeFormSpawner
c.KubeSpawner.singleuser_image_spec = 'gcr.io/kubeflow/tensorflow-notebook'
c.KubeSpawner.cmd = 'start-singleuser.sh'
c.KubeSpawner.args = ['--allow-root']
# First pulls can be really slow, so let's give it a big timeout
c.KubeSpawner.start_timeout = 60 * 10
###################################################


###################################################
### Authenticator Options
###################################################
c.JupyterHub.authenticator_class = 'dummyauthenticator.DummyAuthenticator'
# c.JupyterHub.authenticator_class = GitHubOAuthenticator
# c.GitHubOAuthenticator.oauth_callback_url = '<placeholder>'
# c.GitHubOAuthenticator.client_id = '<placeholder>'
# c.GitHubOAuthenticator.client_secret = '<placeholder>'


###################################################
### Persistent volume options
###################################################
c.KubeSpawner.user_storage_pvc_ensure = True
# How much disk space do we want?
c.KubeSpawner.user_storage_capacity = '10Gi'
c.KubeSpawner.pvc_name_template = 'claim-{username}{servername}'
",

	local volumes = [
{
            'name': 'volume-{username}{servername}',
            'persistentVolumeClaim': {
                'claimName': 'claim-{username}{servername}'
            },
        },
        {
            'name': 'deepvariant-nfs',
            'persistentVolumeClaim': {
                'claimName': 'nfs'
            },
        },
    ],

local volumeMounts = [
        {
            // This should point to homedir of the user in the image
            'mountPath': '/home/jovyan/pd',
            'name': 'volume-{username}{servername}'
        },
        {
            'mountPath': '/home/jovyan/deepvariant-pd',
            'name': 'deepvariant-nfs'
        },
    ],


   // TODO(jlewi): We should make volumes easily configurable. The user should be able to specify
   // volumes per environment and then based on that the Kube config should be generated appropriately
   // local extendedBaseKubeConfigSpawner = baseKubeConfigSpawner    
   //		+ "\nc.KubeSpawner.volumes = " + std.manifestPython(volumes)
   //		+ "\nc.KubeSpawner.volume_mounts = " + std.manifestPython(volumeMounts),

   local extendedBaseKubeConfigSpawner = baseKubeConfigSpawner,
   jupyterHubConfigMap: {
	  "apiVersion": "v1", 
	  "data": {	    
	    "jupyterhub_config.py": extendedBaseKubeConfigSpawner,
	  }, 
	  "kind": "ConfigMap", 
	  "metadata": {
	    "name": "jupyterhub-config",
	    namespace: namespace,
	  },
   },

   jupyterHubService: {
	  "apiVersion": "v1", 
	  "kind": "Service", 
	  "metadata": {
	    "labels": {
	      "app": "tf-hub"
	    }, 
	    "name": "tf-hub-0",
	    namespace: namespace,
	  }, 
	  "spec": {
	    "clusterIP": "None", 
	    "ports": [
	      {
	        "name": "hub", 
	        "port": 8000
	      }
	    ], 
	    "selector": {
	      "app": "tf-hub"
	    }
	  }
   },

   jupyterHubLoadBalancer: {
	  "apiVersion": "v1", 
	  "kind": "Service", 
	  "metadata": {
	    "labels": {
	      "app": "tf-hub"
	    }, 
	    "name": "tf-hub-lb",
	    "namespace": namespace,
	  }, 
	  "spec": {
	    "ports": [
	      {
	        "name": "http", 
	        "port": 80, 
	        "targetPort": 8000
	      }
	    ], 
	    "selector": {
	      "app": "tf-hub"
	    }, 
	    "type": "LoadBalancer"
	  }
	},

	jupyterHub(image): {
	  "apiVersion": "apps/v1beta1", 
	  "kind": "StatefulSet", 
	  "metadata": {
	    "name": "tf-hub",
	    "namespace": namespace,
	  }, 
	  "spec": {
	    "replicas": 1, 
	    "serviceName": "", 
	    "template": {
	      "metadata": {
	        "labels": {
	          "app": "tf-hub"
	        }
	      }, 
	      "spec": {
	        "containers": [
	          {
	            "command": [
	              "jupyterhub", 
	              "-f", 
	              "/etc/config/jupyterhub_config.py"
	            ], 
	            "image": image, 
	            "name": "tf-hub", 
	            "volumeMounts": [
	              {
	                "mountPath": "/etc/config", 
	                "name": "config-volume"
	              }
	            ]
	          }
	        ], 
	        "serviceAccountName": "jupyter-hub", 
	        "volumes": [
	          {
	            "configMap": {
	              "name": "jupyterhub-config"
	            }, 
	            "name": "config-volume"
	          }
	        ]
	      }
	    }, 
	    "updateStrategy": {
	      "type": "RollingUpdate"
	    }
	  }
	},

   jupyterHubRole: {
	  "apiVersion": "rbac.authorization.k8s.io/v1beta1", 
	  "kind": "Role", 
	  "metadata": {
	    "name": "jupyter-role", 
	    "namespace": namespace,
	  }, 
	  "rules": [
	    {
	      "apiGroups": [
	        "*"
	      ], 
	      // TODO(jlewi): This is very permissive so we may want to lock this down.
	      "resources": [
	        "*"
	      ], 
	      "verbs": [
	        "*"
	      ]
	    }
	  ]
	},
    
   jupyterHubServiceAccount: {
      "apiVersion": "v1", 
      "kind": "ServiceAccount", 
      "metadata": {
        "labels": {
          "app": "jupyter-hub"
        }, 
        "name": "jupyter-hub",
        "namespace": namespace,
      }
    },

	jupyterHubRoleBinding: {
	  "apiVersion": "rbac.authorization.k8s.io/v1beta1", 
	  "kind": "RoleBinding", 
	  "metadata": {
	    "name": "jupyter-role", 
	    "namespace": namespace,
	  }, 
	  "roleRef": {
	    "apiGroup": "rbac.authorization.k8s.io", 
	    "kind": "Role", 
	    "name": "jupyter-role"
	  }, 
	  "subjects": [
	    {
	      "kind": "ServiceAccount", 
	      "name": "jupyter-hub", 
	      "namespace": namespace,
	    }
	  ]
	},
  }, // parts
}