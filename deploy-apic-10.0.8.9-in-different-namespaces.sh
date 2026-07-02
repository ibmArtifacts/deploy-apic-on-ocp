#!/bin/bash
#Deployment of apic v10.0.8.9 in different namespaces

export NAMESPACE_OPERATOR=apic-ops
export NAMESPACE_MGMT=apic-mgmt
export NAMESPACE_PTL=apic-ptl
export NAMESPACE_A7S=apic-a7s
export NAMESPACE_GW=apic-gw
export NAMESPACE_DEFAULT=default
export STACK_HOST=YOUR_HOST_DOMAIN_HERE
export STORAGE_CLASS=YOUR_STORAGECLASS_HERE
export CASE_NAME_APIC=ibm-apiconnect
export CASE_VERSION_APIC=5.11.0
export APIC_CHANNEL=v5.11-sc2
export CASE_NAME_COMMON_SERVICE=ibm-cp-common-services
export CASE_VERSION_COMMON_SERVICE=4.6.21
export COMMON_SERVICES_CHANNEL=v4.6
export LICENSE_USE=nonproduction
export APIC_PROFILE=n1xc7.m48
export LICENSE_ID=L-HTFS-UAXYM3
export ENTITLEMENT_KEY=YOUR_ENTITLEMENT_KEY_HERE
#get your entitlement key here: https://myibm.ibm.com/products-services/containerlibrary
export APP_PRODUCT_VERSION=10.0.8.9
export PROFILE_MGMT=n1xc2.m16
export PROFILE_GWY=n1xc1.m8
export PROFILE_A7S=n1xc2.m16
export PROFILE_PTL=n1xc2.m8
export STORAGE_TYPE=shared
export DATA_VOLUME_SIZE=500Gi

oc new-project ${NAMESPACE_OPERATOR}
oc new-project ${NAMESPACE_MGMT}
oc new-project ${NAMESPACE_GW}
oc new-project ${NAMESPACE_PTL}
oc new-project ${NAMESPACE_A7S}
oc project ${NAMESPACE_OPERATOR}


echo "Creating ibm-entitlement-key secret to use to download images from ibm registry."
oc create secret docker-registry ibm-entitlement-key \
        --docker-server=cp.icr.io \
        --docker-username=cp \
        --docker-password=${ENTITLEMENT_KEY}

echo "Create common services namespace"
oc create ns ibm-common-services


echo "This section downloads and applies the APIC catalog sources to the cluster."
echo "1. Downloading the files for the operators required by APIC"
oc ibm-pak get ${CASE_NAME_APIC} --version ${CASE_VERSION_APIC}

echo "2. Generate the catalog sources for APIC"
oc ibm-pak generate mirror-manifests ${CASE_NAME_APIC} icr.io --version ${CASE_VERSION_APIC}

echo "3. Applying the catalog sources"
oc apply -f ~/.ibm-pak/data/mirror/${CASE_NAME_APIC}/${CASE_VERSION_APIC}/catalog-sources.yaml

echo "4. Confirming that catalog sources have been created in the openshift-marketplace namespace"
oc get catalogsource -n openshift-marketplace


echo "This section downloads and applies the IBM Cloud Pak Foundational Services (Common Services) catalog sources the cluster."
echo "1. Downloading the files for the operators required by the Common Services"
oc ibm-pak get ${CASE_NAME_COMMON_SERVICE} --version ${CASE_VERSION_COMMON_SERVICE}

echo "2. Generate the catalog sources for the Common Services"
oc ibm-pak generate mirror-manifests ${CASE_NAME_COMMON_SERVICE} icr.io --version ${CASE_VERSION_COMMON_SERVICE}

echo "3. Applying the catalog sources"
oc apply -f ~/.ibm-pak/data/mirror/${CASE_NAME_COMMON_SERVICE}/${CASE_VERSION_COMMON_SERVICE}/catalog-sources.yaml

echo "4. Confirming that catalog sources have been created in the openshift-marketplace namespace"
oc get catalogsource -n openshift-marketplace


echo "Creating operator group to install the operators into the operator namespace."
cat <<EOF | oc apply -f - 
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: apic-operator-group
  namespace: ${NAMESPACE_OPERATOR}
EOF


echo "Subscribe to APIC."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${CASE_NAME_APIC}
  namespace: ${NAMESPACE_OPERATOR}
spec:
  channel: ${APIC_CHANNEL}
  name: ${CASE_NAME_APIC}
  source: ibm-apiconnect-catalog
  sourceNamespace: openshift-marketplace
EOF

echo "Installing RH Cert-Manager:"
oc create ns cert-manager
echo "Creating RH Cert-Manager OperatorGroup..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator-group
  namespace: cert-manager
spec:
  targetNamespaces:
  - cert-manager
EOF

echo "Create Subscription for cert-manager operator:"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for cert-manager operator to be installed..."
sleep 10

# Check operator installation status
echo "Checking operator installation status..."
for i in {1..30}; do
    if oc get csv -n cert-manager | grep -q "Succeeded"; then
        echo "Operator installed successfully!"
        break
    fi
    echo "Waiting for operator... (attempt $i/30)"
    sleep 10
done

echo "Operator Status:"
oc get csv -n cert-manager

echo "Creating cert-manager instance..."
cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: CertManager
metadata:
  name: cluster
spec:
  managementState: Managed
  logLevel: Normal
  operatorLogLevel: Normal
EOF

# Wait for cert-manager pods to be ready
echo ""
echo "Waiting for cert-manager pods to be ready..."
sleep 15

echo "Checking cert-manager deployment status..."
oc wait --for=condition=Available --timeout=300s \
  deployment/cert-manager -n cert-manager || true
oc wait --for=condition=Available --timeout=300s \
  deployment/cert-manager-webhook -n cert-manager || true
oc wait --for=condition=Available --timeout=300s \
  deployment/cert-manager-cainjector -n cert-manager || true


echo "RH Cert-Manager completed"
echo ""
echo "Cert-manager pods:"
oc get pods -n cert-manager
echo ""
echo "Cert-manager deployments:"
oc get deployments -n cert-manager
echo ""
echo "To verify installation, run:"
echo "oc get all -n cert-manager"
echo "oc get certmanager cluster -o yaml"


echo "Create ibm-common-services-opearators subscription."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-common-service-operator
  namespace: openshift-operators
spec:
  channel: ${COMMON_SERVICES_CHANNEL}
  name: ibm-common-service-operator
  source: opencloud-operators
  sourceNamespace: openshift-marketplace
  STORAGE_CLASS: ${STORAGE_CLASS}
EOF


echo "Setting up the ingress issuer for MGMT."
oc project ${NAMESPACE_MGMT}
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigning-issuer
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: selfsigning-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ingress-issuer
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: ingress-issuer
spec:
  ca:
    secretName: ingress-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ingress-ca
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: ingress-ca
spec:
  secretName: ingress-ca
  commonName: "ingress-ca"
  usages:
  - digital signature
  - key encipherment
  - cert sign
  isCA: true
  duration: 87600h # 10 years
  renewBefore: 720h # 30 days
  privateKey:
    rotationPolicy: Always
  issuerRef:
    name: selfsigning-issuer
    kind: Issuer
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: portal-admin-client
  labels: 
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: portal-admin-client
spec:
  subject:
    organizations:
    - cert-manager
  commonName: portal-admin-client
  secretName: portal-admin-client
  issuerRef:
    name: ingress-issuer
  usages:
  - "client auth"
  - "signing"
  - "key encipherment"
  duration: 17520h # 2 years
  renewBefore: 720h # 30 days
  privateKey:
    rotationPolicy: Always
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gateway-client-client
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: gateway-client-client
spec:
  subject:
    organizations:
    - cert-manager
  commonName: gateway-client-client
  secretName: gateway-client-client
  issuerRef:
    name: ingress-issuer
  usages:
  - "client auth"
  - "signing"
  - "key encipherment"
  duration: 17520h # 2 years
  renewBefore: 720h # 30 days
  privateKey:
    rotationPolicy: Always
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: analytics-ingestion-client
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: analytics-ingestion-client
spec:
  subject:
    organizations:
    - cert-manager
  commonName: analytics-ingestion-client
  secretName: analytics-ingestion-client
  issuerRef:
    name: ingress-issuer
  usages:
  - "client auth"
  - "signing"
  - "key encipherment"
  duration: 17520h # 2 years
  renewBefore: 720h # 30 days
  privateKey:
    rotationPolicy: Always
EOF

echo "Installing the mgmt subsystem in separate namespaces."
oc project ${NAMESPACE_MGMT}
cat <<EOF | oc apply -f -
apiVersion: management.apiconnect.ibm.com/v1beta1
kind: ManagementCluster
metadata:
  namespace: ${NAMESPACE_MGMT}
  name: management
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: management
  annotations:
    apiconnect-operator/cp4i: "false"
spec:
  version: $APP_PRODUCT_VERSION
  profile: $PROFILE_MGMT
  portal:
    admin:
      secretName: portal-admin-client
  analytics:
    ingestion:
      secretName: analytics-ingestion-client
  gateway:
    client:
      secretName: gateway-client-client
  cloudManagerEndpoint:
    annotations:
      cert-manager.io/issuer: ingress-issuer
    hosts:
    - name: admin.$STACK_HOST
      secretName: cm-endpoint
  apiManagerEndpoint:
    annotations:
      cert-manager.io/issuer: ingress-issuer
    hosts:
    - name: manager.$STACK_HOST
      secretName: apim-endpoint
  platformAPIEndpoint:
    annotations:
      cert-manager.io/issuer: ingress-issuer
    hosts:
    - name: api.$STACK_HOST
      secretName: api-endpoint
  consumerAPIEndpoint:
    annotations:
      cert-manager.io/issuer: ingress-issuer
    hosts:
    - name: consumer.$STACK_HOST
      secretName: consumer-endpoint
  consumerCatalogEndpoint:
    annotations:
      cert-manager.io/issuer: ingress-issuer
    hosts: 
    - name: consumer-catalog.$STACK_HOST
      secretName: consumer-catalog-endpoint
  databaseVolumeClaimTemplate:
    storageClassName: ${STORAGE_CLASS}
  microServiceSecurity: certManager
  certManagerIssuer:
    name: selfsigning-issuer
    kind: Issuer
  license:
    accept: true
    use: $LICENSE_USE
    license: '$LICENSE_ID'
EOF




echo "Extract ingress-ca and management-ca from ${NAMESPACE_MGMT} ns and add them to ns ${NAMESPACE_GW}, ${NAMESPACE_PTL}, and ${NAMESPACE_A7S}"
SECRETS=("ingress-ca" "management-ca")
TARGET_NAMESPACES=("${NAMESPACE_GW}" "${NAMESPACE_PTL}" "${NAMESPACE_A7S}")

strip_and_apply() {
  local secret=$1
  local dst_ns=$2

  echo "  Applying '${secret}' to namespace '${dst_ns}'..."

  oc get secret "${secret}" -n "${NAMESPACE_MGMT}" -o json \
    | jq 'del(
        .metadata.creationTimestamp,
        .metadata.namespace,
        .metadata.resourceVersion,
        .metadata.uid,
        .metadata.selfLink
      )' \
    | jq ".metadata.namespace = \"${dst_ns}\"" \
    | oc apply -n "${dst_ns}" -f -
}

for SECRET in "${SECRETS[@]}"; do
  echo ""
  echo "Exporting '${SECRET}' from '${NAMESPACE_MGMT}'..."

  # Verify the secret exists in the source namespace before attempting export
  if ! oc get secret "${SECRET}" -n "${NAMESPACE_MGMT}" &>/dev/null; then
    echo "  ERROR: Secret '${SECRET}' not found in namespace '${NAMESPACE_MGMT}'. Skipping."
    continue
  fi

  for NS in "${TARGET_NAMESPACES[@]}"; do
    strip_and_apply "${SECRET}" "${NS}"
  done
done

echo ""
echo "Done. Summary:"
for NS in "${TARGET_NAMESPACES[@]}"; do
  echo ""
  echo "  Namespace: ${NS}"
  for SECRET in "${SECRETS[@]}"; do
    STATUS=$(oc get secret "${SECRET}" -n "${NS}" --no-headers 2>/dev/null \
      && echo "OK" || echo "MISSING")
    echo "    ${SECRET}: ${STATUS}"
  done
done







oc project ${NAMESPACE_GW}
echo "Creating gateway admin secret..."
oc create secret generic admin-secret --from-literal=password=admin

echo "Applying the GW common-issuer-and-gateway-certs"
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigning-issuer
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: selfsigning-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ingress-issuer
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: ingress-issuer
spec:
  ca:
    secretName: ingress-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gateway-service
  labels:
    app.kubernetes.io/instance: gatewaycluster
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: gateway-service
spec:
  commonName: gateway-service
  secretName: gateway-service
  issuerRef:
    name: ingress-issuer
  usages:
  - "client auth"
  - "signing"
  - "key encipherment"
  duration: 17520h # 2 years
  renewBefore: 720h # 30 days
  privateKey:
    rotationPolicy: Always
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gateway-peering
  labels:
    app.kubernetes.io/instance: gatewaycluster
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: gateway-peering
spec:
  commonName: gateway-peering
  secretName: gateway-peering
  issuerRef:
    name: ingress-issuer
  usages:
  - "server auth"
  - "client auth"
  - "signing"
  - "key encipherment"
  duration: 17520h # 2 years
  renewBefore: 720h # 30 days
  privateKey:
    rotationPolicy: Always
EOF

echo "Installing the gwy subsystem in a shared namespace."
cat <<EOF | oc apply -f -
apiVersion: gateway.apiconnect.ibm.com/v1beta1
kind: GatewayCluster
metadata:
  name: gwv6
  labels:
    app.kubernetes.io/instance: gateway
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: gwv6
  annotations:
    apiconnect-operator/cp4i: "false"
spec:
  version: $APP_PRODUCT_VERSION
  profile: $PROFILE_GWY
  apicGatewayServiceV5CompatibilityMode: false
  mgmtPlatformEndpointCASecret:
    secretName: ingress-ca
  mgmtPlatformEndpointSvcCASecret:
    secretName: management-ca
  gatewayEndpoint:
    annotations:
      cert-manager.io/issuer: ingress-issuer
    hosts:
    - name: rgw.$STACK_HOST
      secretName: gwv6-endpoint
  gatewayManagerEndpoint:
    annotations:
      cert-manager.io/issuer: ingress-issuer
    hosts:
    - name: rgwd.$STACK_HOST
      secretName: gwv6-manager-endpoint
  apicGatewayServiceTLS:
    secretName: gateway-service
  apicGatewayPeeringTLS:
    secretName: gateway-peering
  datapowerLogLevel: 3
  license:
    accept: true
    use: $LICENSE_USE
    license: '$LICENSE_ID'
  tokenManagementService:
    enabled: true
    storage:
      storageClassName: $STORAGE_CLASS
      volumeSize: 30Gi
  adminUser:
    secretName: admin-secret
  mtlsValidateClient: true
  # syslogConfig:
  #   enabled: false # if true, provide below details
  #   remoteHost: $DATAPOWER_SYSLOG_TCP_REMOTE_HOST # must be a string
  #   remotePort: $DATAPOWER_SYSLOG_TCP_REMOTE_PORT # must be an int
  #   secretName: $DATAPOWER_SYSLOG_TCP_TLS_SECRET # must be a string
EOF






oc project ${NAMESPACE_PTL}
echo "Applying the PTL common-issuers"
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigning-issuer
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: selfsigning-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ingress-issuer
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: ingress-issuer
spec:
  ca:
    secretName: ingress-ca
EOF

echo "Installing the ptl subsystem in a shared namespace."
cat <<EOF | oc apply -f -
apiVersion: portal.apiconnect.ibm.com/v1beta1
kind: PortalCluster
metadata:
  name: portal
  labels:
    app.kubernetes.io/instance: portal
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: portal
  annotations:
    apiconnect-operator/cp4i: "false"
spec:
  version: $APP_PRODUCT_VERSION
  profile: $PROFILE_PTL
  mgmtPlatformEndpointCASecret:
    secretName: ingress-ca
  mgmtConsumerEndpointCASecret:
    secretName: ingress-ca
  mgmtPlatformEndpointSvcCASecret:
    secretName: management-ca
  mgmtConsumerEndpointSvcCASecret:
    secretName: management-ca
  portalAdminEndpoint:
    annotations:
      cert-manager.io/issuer: ingress-issuer
    hosts:
    - name: api.portal.$STACK_HOST
      secretName: portal-admin
  portalUIEndpoint:
    annotations:
      cert-manager.io/issuer: ingress-issuer
    hosts:
    - name: portal.$STACK_HOST
      secretName: portal-web
  databaseVolumeClaimTemplate:
    storageClassName: $STORAGE_CLASS
    volumeSize: 200Gi
  databaseLogsVolumeClaimTemplate:
    storageClassName: $STORAGE_CLASS
    volumeSize: 12Gi
  webVolumeClaimTemplate:
    storageClassName: $STORAGE_CLASS
    volumeSize: 200Gi
  backupVolumeClaimTemplate:
    storageClassName: $STORAGE_CLASS
    volumeSize: 120Gi
  adminVolumeClaimTemplate:
    storageClassName: $STORAGE_CLASS
    volumeSize: 20Gi
  certVolumeClaimTemplate:
    storageClassName: $STORAGE_CLASS
    volumeSize: 4Gi
  adminClientSubjectDN: CN=portal-admin-client,O=cert-manager
  microServiceSecurity: certManager
  certManagerIssuer:
    name: selfsigning-issuer
    kind: Issuer
  license:
    accept: true
    use: $LICENSE_USE
    license: '$LICENSE_ID'
EOF


oc project ${NAMESPACE_A7S}
echo "Applying the a7s common-issuers"
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigning-issuer
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: selfsigning-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ingress-issuer
  labels:
    app.kubernetes.io/instance: management
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: ingress-issuer
spec:
  ca:
    secretName: ingress-ca
EOF

echo "Installing the a7s subsystem in a shared namespace."
cat <<EOF | oc apply -f -
apiVersion: analytics.apiconnect.ibm.com/v1beta1
kind: AnalyticsCluster
metadata:
  name: analytics
  labels:
    app.kubernetes.io/instance: analytics
    app.kubernetes.io/managed-by: ibm-apiconnect
    app.kubernetes.io/name: analytics
  annotations:
    apiconnect-operator/cp4i: 'false'
spec:
  version: $APP_PRODUCT_VERSION
  license:
    accept: true
    use: $LICENSE_USE
    license: '$LICENSE_ID'
  profile: $PROFILE_A7S
  mgmtPlatformEndpointCASecret:
    secretName: ingress-ca
  mgmtPlatformEndpointSvcCASecret:
    secretName: management-ca
  microServiceSecurity: certManager
  certManagerIssuer:
    name: selfsigning-issuer
    kind: Issuer
  ingestion:
    endpoint:
      annotations:
        cert-manager.io/issuer: ingress-issuer
      hosts: 
      - name: ai.$STACK_HOST
        secretName: analytics-ai-endpoint
    clientSubjectDN: CN=analytics-ingestion-client,O=cert-manager
  storage:
    type: $STORAGE_TYPE
    shared:
      volumeClaimTemplate:
        storageClassName: $STORAGE_CLASS
        volumeSize: $DATA_VOLUME_SIZE 
   #master: # uncomment this section if you set storage.type = dedicated.
   #  volumeClaimTemplate:
   #    storageClassName: $STORAGE_CLASS
EOF


