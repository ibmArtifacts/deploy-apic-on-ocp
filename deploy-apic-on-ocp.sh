#!/bin/bash

export NAMESPACE=ENTER_YOUR_APIC_NAMESPACE_HERE
export CASE_NAME=ibm-apiconnect
export CASE_VERSION=5.7.0
export APIC_CHANNEL=v5.7-sc2
export LICENSE_USE=nonproduction
export APIC_PROFILE=UPDATE_YOUR_PROFILE
export APIC_VERSION=10.0.8.5
export STORAGECLASS=UPDATE_YOUR_STORAGE_CLASS
export LICENSE=L-HTFS-UAXYM3
export ENTITLEMENT_KEY=ENTER_YOUR_ENTITLEMENT_KEY
#get your entitlement key here: https://myibm.ibm.com/products-services/containerlibrary

oc new-project $NAMESPACE
oc project $NAMESPACE

echo "Verfying environment variables: "
echo "NAMESPACE:" ${NAMESPACE}
echo "CASE_NAME:" ${CASE_NAME}
echo "CASE_VERSION:" ${CASE_VERSION}
echo "APIC_CHANNEL:" ${APIC_CHANNEL}
echo "LICENSE_USE:" ${LICENSE_USE}
echo "LICENSE:" ${LICENSE}
echo "APIC_PROFILE:" ${APIC_PROFILE}
echo "APIC_VERSION:" ${APIC_VERSION}
echo "STORAGECLASS:" ${STORAGECLASS}

echo "Creating ibm-entitlement-key secret to use to download images from ibm registry."
oc create secret docker-registry ibm-entitlement-key \
        --docker-server=cp.icr.io \
        --docker-username=cp \
        --docker-password=$ENTITLEMENT_KEY

echo "Adding catalog sources"
oc apply --filename https://raw.githubusercontent.com/IBM/cloud-pak/master/repo/case/ibm-cp-common-services/4.6.20/OLM/catalog-sources.yaml
oc apply --filename https://raw.githubusercontent.com/IBM/cloud-pak/master/repo/case/ibm-apiconnect/5.7.0/OLM/catalog-sources.yaml
oc apply --filename https://raw.githubusercontent.com/IBM/cloud-pak/master/repo/case/ibm-datapower-operator/1.11.9/OLM/catalog-sources.yaml

echo "Setting storage for CommonService."
cat <<EOF | oc apply -f -
apiVersion: operator.ibm.com/v3
kind: CommonService
metadata:
  name: common-service
  namespace: ${NAMESPACE}
spec:
  size: as-is
  storageClass: ${STORAGECLASS}
EOF

echo "Creating namespace for RH cert-manager."
oc new-project cert-manager-operator

echo "Subscribing to RH-cert-manager."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
#  generation: 1
  labels:
    operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator: ''
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
#  startingCSV: cert-manager-operator.v1.14.1
EOF

echo "Creating operator group for RH cert-manager."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  annotations:
    olm.providedAPIs: CertManager.v1alpha1.operator.openshift.io,Certificate.v1.cert-manager.io,CertificateRequest.v1.cert-manager.io,Challenge.v1.acme.cert-manager.io,ClusterIssuer.v1.cert-manager.io,Issuer.v1.cert-manager.io,Order.v1.acme.cert-manager.io
  generateName: cert-manager-operator
#  generation: 1
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
  upgradeStrategy: Default
status:
  namespaces:
  - cert-manager-operator
EOF

echo "Subscribe to APIC."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${CASE_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: ${APIC_CHANNEL}
  installPlanApproval: Auto
  name: ${CASE_NAME}
  source: ibm-apiconnect-catalog
  sourceNamespace: openshift-marketplace
EOF

echo "Create APIC cluster."
cat <<EOF | oc apply -f -
apiVersion: apiconnect.ibm.com/v1beta1
kind: APIConnectCluster
metadata:
  name: apic
  annotations:
    apiconnect-operator/cp4i: 'true'
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: ${LICENSE}
    metric: VIRTUAL_PROCESSOR_CORE
    use: ${LICENSE_USE}
  analytics:
    mtlsValidateClient: true
  portal:
    mtlsValidateClient: true
  profile: ${APIC_PROFILE}
  version: ${APIC_VERSION}
  storageClassName: ${STORAGECLASS}
EOF

echo "The APIC Operators and APIC instance are now being deployed. Please be patient and check on the Installed Operators for any errors."

