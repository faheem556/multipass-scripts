#!/bin/bash -ex

pushd $(dirname 0)
source ./env.sh

pre_req() {
  if [ ! -f ~/.ssh/$SSH_KEY ]; then
    ssh-keygen -b 2048 -f ~/.ssh/$SSH_KEY -t rsa -q -N ""
  fi

  cat <<EOF > ./cloud-init.yaml
#cloud-config
ssh_authorized_keys:
- $(cat ~/.ssh/$SSH_KEY.pub)

package_update: true

packages:
- curl
- jq
EOF
}

create_vms() {
  if ! multipass info $K3S_SERVER > /dev/null 2>&1; then
    multipass launch --name $K3S_SERVER \
    --mem 1G \
    --cpus 1 \
    --disk 5G \
    --cloud-init ./cloud-init.yaml
  fi 

  if ! multipass info $K3S_AGENT1 > /dev/null 2>&1; then
    multipass launch --name $K3S_AGENT1 \
    --mem 4G \
    --cpus 1 \
    --disk 5G \
    --cloud-init ./cloud-init.yaml
  fi

  if ! multipass info $K3S_AGENT2 > /dev/null 2>&1; then
    multipass launch --name $K3S_AGENT2 \
    --mem 4G \
    --cpus 1 \
    --disk 5G \
    --cloud-init ./cloud-init.yaml
  fi
}

install_k3s_server() {

  # install k3s server
  export K3S_SERVER_IP=$(multipass info $K3S_SERVER --format json | jq -r ".info.\"$K3S_SERVER\".ipv4[0]")
  export K3S_SERVER_IFACE=$(multipass exec $K3S_SERVER ip route show to default | awk '{ print $5; exit }')

  k3sup install \
    --ip=$K3S_SERVER_IP \
    --user=ubuntu \
    --ssh-key=~/.ssh/$SSH_KEY \
    --k3s-version=$KUBE_VERSION \
    --local-path=config.demo.yaml \
    --context=demo \
    --cluster \
    --tls-san $VIP \
    --k3s-extra-args="--disable servicelb --node-taint node-role.kubernetes.io/master=true:NoSchedule"
}

setup_kube_vip () {
  # setup kube-vip
  multipass transfer ./files/kube-vip-rbac.yaml $K3S_SERVER:./
  multipass exec $K3S_SERVER sudo mv kube-vip-rbac.yaml /var/lib/rancher/k3s/server/manifests/

  multipass exec $K3S_SERVER sudo crictl pull docker.io/plndr/kube-vip:0.3.2

  multipass exec $K3S_SERVER -- sudo ctr run --rm --net-host docker.io/plndr/kube-vip:0.3.2 vip /kube-vip manifest daemonset \
    --arp \
    --interface $K3S_SERVER_IFACE \
    --address $VIP \
    --controlplane \
    --services \
    --leaderElection \
    --taint \
    --inCluster | tee ./files/kube-vip.yaml

  yq e '.spec.template.spec.tolerations[0].operator="Exists"' -i ./files/kube-vip.yaml

  multipass transfer ./files/kube-vip.yaml $K3S_SERVER:./
  multipass exec $K3S_SERVER sudo mv kube-vip.yaml /var/lib/rancher/k3s/server/manifests/
}

add_workers() {
  # add workers
  k3sup join --ip=$(multipass info $K3S_AGENT1 --format json | jq -r ".info.\"$K3S_AGENT1\".ipv4[0]") \
    --server-user=ubuntu \
    --server-host=$K3S_SERVER_IP \
    --ssh-key=~/.ssh/$SSH_KEY \
    --user=ubuntu \
    --k3s-version=$KUBE_VERSION

  k3sup join --ip=$(multipass info $K3S_AGENT2 --format json | jq -r ".info.\"$K3S_AGENT2\".ipv4[0]") \
    --server-user=ubuntu \
    --server-host=$K3S_SERVER_IP \
    --ssh-key=~/.ssh/$SSH_KEY \
    --user=ubuntu \
    --k3s-version=$KUBE_VERSION
}

install_metallb() {
  kubectl apply --kubeconfig ./config.demo.yaml -f https://raw.githubusercontent.com/metallb/metallb/v0.9.5/manifests/namespace.yaml
  kubectl apply --kubeconfig ./config.demo.yaml -f https://raw.githubusercontent.com/metallb/metallb/v0.9.5/manifests/metallb.yaml

  # create secret
  kubectl create secret generic \
    -n metallb-system memberlist \
    --from-literal=secretkey="$(openssl rand -base64 128)" \
    --kubeconfig ./config.demo.yaml

  cat <<-EOF | kubectl apply --kubeconfig ./config.demo.yaml -f -
    apiVersion: v1
    kind: ConfigMap
    metadata:
      namespace: metallb-system
      name: config
    data:
      config: |
        address-pools:
        - name: default
        protocol: layer2
        addresses:
        - 192.168.64.240-192.168.64.250
EOF
}

{
  pre_req
  create_vms
  install_k3s_server
  setup_kube_vip
  add_workers
  install_metallb
}

popd