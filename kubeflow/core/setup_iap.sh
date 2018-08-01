#!/bin/bash
#
# A simple shell script to enable IAP and configure timeouts by using gcloud.
[ -z ${CLIENT_ID} ] && echo Error CLIENT_ID must be set && exit 1
[ -z ${CLIENT_SECRET} ] && echo Error CLIENT_SECRET must be set && exit 1
[ -z ${NAMESPACE} ] && echo Error NAMESPACE must be set && exit 1
[ -z ${SERVICE} ] && echo Error SERVICE must be set && exit 1

apk add --update jq
curl https://storage.googleapis.com/kubernetes-release/release/v1.9.4/bin/linux/amd64/kubectl > /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

# Stagger init of replicas when acquiring lock
sleep $(( $RANDOM % 5 + 1 ))

# We acquire a lock because we want to ensure  there is a single process
# trying to modify the backend at a time.
kubectl get svc ${SERVICE} -o json > service.json
LOCK=$(jq -r ".metadata.annotations.iaplock" service.json)

NOW=$(date -u +'%s')
if [[ -z "${LOCK}" || "${LOCK}" == "null" ]]; then
LOCK_T=$NOW
else
LOCK_T=$(echo "${LOCK}" | cut -d' ' -f2)
fi
LOCK_AGE=$(( $NOW - $LOCK_T ))
LOCK_TTL=120
if [[ -z "${LOCK}" || "${LOCK}" == "null" || "${LOCK_AGE}" -gt "${LOCK_TTL}" ]]; then
jq -r ".metadata.annotations.iaplock=\"$(hostname -s) ${NOW}\"" service.json > service_lock.json
kubectl apply -f service_lock.json 2>/dev/null
if [[ $? -eq 0 ]]; then
  echo "Acquired lock on service annotation to update IAP."
else
  echo "WARN: Failed to acquire lock on service annotation."
  exit 1
fi
else
echo "WARN: Lock on service annotation already acquired by: $LOCK, age: $LOCK_AGE, TTL: $LOCK_TTL"
sleep 20
exit 1
fi

PROJECT=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
if [ -z ${PROJECT} ]; then
echo Error unable to fetch PROJECT from compute metadata
exit 1
fi

PROJECT_NUM=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/numeric-project-id)
if [ -z ${PROJECT_NUM} ]; then
echo Error unable to fetch PROJECT_NUM from compute metadata
exit 1
fi

if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
  echo Using VM Service Account
else
  # Activate the service account
  gcloud auth activate-service-account --key-file=${GOOGLE_APPLICATION_CREDENTIALS}
fi

# Print out the config for debugging
gcloud config list

NODE_PORT=$(kubectl --namespace=${NAMESPACE} get svc ${SERVICE} -o jsonpath='{.spec.ports[0].nodePort}')
while [[ -z ${BACKEND_ID} ]];
do BACKEND_ID=$(gcloud compute --project=${PROJECT} backend-services list --filter=name~k8s-be-${NODE_PORT}- --format='value(id)');
echo "Waiting for backend id PROJECT=${PROJECT} NAMESPACE=${NAMESPACE} SERVICE=${SERVICE} filter=name~k8s-be-${NODE_PORT}- ...";
sleep 2;
done
echo BACKEND_ID=${BACKEND_ID}

NODE_PORT=$(kubectl --namespace=${NAMESPACE} get svc ${SERVICE} -o jsonpath='{.spec.ports[0].nodePort}')
BACKEND_SERVICE=$(gcloud --project=${PROJECT} compute backend-services list --filter=name~k8s-be-${NODE_PORT}- --uri)
# Enable IAP on the backend service:
gcloud --project=${PROJECT} compute backend-services update ${BACKEND_SERVICE} \
    --global \
    --iap=enabled,oauth2-client-id=${CLIENT_ID},oauth2-client-secret=${CLIENT_SECRET}

while [[ -z ${HEALTH_CHECK_URI} ]];
do HEALTH_CHECK_URI=$(gcloud compute --project=${PROJECT} health-checks list --filter=name~k8s-be-${NODE_PORT}- --uri);
echo "Waiting for the healthcheck resource PROJECT=${PROJECT} NODEPORT=${NODE_PORT} SERVICE=${SERVICE}...";
sleep 2;
done

# Since we create the envoy-ingress ingress object before creating the envoy
# deployment object, healthcheck will not be configured correctly in the GCP
# load balancer. It will default the healthcheck request path to a value of
# / instead of the intended /healthz.
# Manually update the healthcheck request path to /healthz
gcloud --project=${PROJECT} compute health-checks update http ${HEALTH_CHECK_URI} --request-path=/healthz

# Since JupyterHub uses websockets we want to increase the backend timeout
echo Increasing backend timeout for JupyterHub
gcloud --project=${PROJECT} compute backend-services update --global ${BACKEND_SERVICE} --timeout=3600

JWT_AUDIENCE="/projects/${PROJECT_NUM}/global/backendServices/${BACKEND_ID}"

# For healthcheck compare.
mkdir -p /var/shared
echo "JWT_AUDIENCE=${JWT_AUDIENCE}" > /var/shared/healthz.env
echo "NODE_PORT=${NODE_PORT}" >> /var/shared/healthz.env
echo "BACKEND_ID=${BACKEND_ID}" >> /var/shared/healthz.env

# TODO(https://github.com/kubeflow/kubeflow/issues/942): We should publish the modified envoy 
# config as a config map and use that in the envoy sidecars.
kubectl get configmap -n ${NAMESPACE} envoy-config -o jsonpath='{.data.envoy-config\.json}' | \
sed -e "s|{{JWT_AUDIENCE}}|${JWT_AUDIENCE}|g" > /var/shared/envoy-config.json

echo "Clearing lock on service annotation"
kubectl patch svc "${SERVICE}" -p "{\"metadata\": { \"annotations\": {\"iaplock\": \"\" }}}"

function checkIAP() {
# created by init container.
. /var/shared/healthz.env 

# If node port or backend id change, so does the JWT audience.
CURR_NODE_PORT=$(kubectl --namespace=${NAMESPACE} get svc ${SERVICE} -o jsonpath='{.spec.ports[0].nodePort}')
CURR_BACKEND_ID=$(gcloud compute --project=${PROJECT} backend-services list --filter=name~k8s-be-${CURR_NODE_PORT}- --format='value(id)')
[ "$BACKEND_ID" == "$CURR_BACKEND_ID" ]
}

# Verify IAP every 10 seconds.
while true; do
if ! checkIAP; then
  echo "$(date) WARN: IAP check failed, restarting container."
  exit 1
fi
sleep 10
done