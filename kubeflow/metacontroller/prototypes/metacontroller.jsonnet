// @apiVersion 0.1
// @name io.ksonnet.pkg.metacontroller
// @description metacontroller Component
// @shortDescription metacontroller Component
// @param name string Name
// @optionalParam namespace string default Namespace for metacontroller 

local metacontroller = import "kubeflow/metacontroller/metacontroller.libsonnet";
local instance = metacontroller.new(env, params);
instance.list(instance.all)
