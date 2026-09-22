#!/usr/bin/env bash
# setup-nfs-rwx.sh — Set up an in-cluster RWX filesystem StorageClass for Kind.
#
# Installs csi-driver-nfs backed by an in-cluster NFS server and creates a
# "nfs-csi" StorageClass. Intended for operators (e.g. SBR) that need a
# ReadWriteMany filesystem StorageClass in a Kind e2e environment.
#
# NOTE: nfs-server-alpine is a KERNEL NFS server; the host must have the nfsd
# kernel module loaded (sudo modprobe nfsd nfs) before running this script.
# NFS client mounts do NOT work under Docker Desktop / podman (LinuxKit kernel).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"
CSI_DRIVER_NFS_VERSION="${CSI_DRIVER_NFS_VERSION:-v4.11.0}"
NFS_NAMESPACE="${NFS_NAMESPACE:-nfs-server}"
STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-nfs-csi}"
NFS_SERVER_IMAGE="${NFS_SERVER_IMAGE:-itsthenetwork/nfs-server-alpine:latest}"

echo "=== Installing csi-driver-nfs ${CSI_DRIVER_NFS_VERSION} ==="
curl -skSL "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/${CSI_DRIVER_NFS_VERSION}/deploy/install-driver.sh" \
  | bash -s "${CSI_DRIVER_NFS_VERSION}" --

echo "=== Waiting for csi-driver-nfs to be ready ==="
"${KUBECTL}" -n kube-system rollout status deployment/csi-nfs-controller --timeout=180s
"${KUBECTL}" -n kube-system rollout status daemonset/csi-nfs-node --timeout=180s

echo "=== Deploying in-cluster NFS server ==="
"${KUBECTL}" create namespace "${NFS_NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL}" apply -f -
cat <<EOF | "${KUBECTL}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-server
  namespace: ${NFS_NAMESPACE}
  labels:
    app: nfs-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-server
  template:
    metadata:
      labels:
        app: nfs-server
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nfs-server
          image: ${NFS_SERVER_IMAGE}
          env:
            - name: SHARED_DIRECTORY
              value: /exports
          ports:
            - name: tcp-2049
              containerPort: 2049
              protocol: TCP
            - name: udp-111
              containerPort: 111
              protocol: UDP
          securityContext:
            privileged: true
          volumeMounts:
            - name: exports
              mountPath: /exports
      volumes:
        - name: exports
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: nfs-server
  namespace: ${NFS_NAMESPACE}
  labels:
    app: nfs-server
spec:
  selector:
    app: nfs-server
  ports:
    - name: tcp-2049
      port: 2049
      protocol: TCP
    - name: udp-111
      port: 111
      protocol: UDP
EOF

echo "=== Waiting for NFS server to be ready ==="
"${KUBECTL}" -n "${NFS_NAMESPACE}" rollout status deployment/nfs-server --timeout=180s

echo "=== Creating StorageClass ${STORAGE_CLASS_NAME} (provisioner nfs.csi.k8s.io) ==="
cat <<EOF | "${KUBECTL}" apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
provisioner: nfs.csi.k8s.io
parameters:
  # nfs-server-alpine exports SHARED_DIRECTORY as the NFS root "/", which is writable.
  server: nfs-server.${NFS_NAMESPACE}.svc.cluster.local
  share: /
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
EOF

echo "=== StorageClasses ==="
"${KUBECTL}" get storageclass
echo "=== NFS CSI storage setup complete ==="
