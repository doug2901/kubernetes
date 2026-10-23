#!/bin/bash
work_folder=./
k8s_version="v1.37.0"
kind_cluster_name="my-lab"
calico_version="v3.32.2"
start_time=$(date +%s)
host_path=~/postgres
container_path=/mnt/data/postgres

function Delete_Cluster () {
    echo "DELETING KIND CLUSTER..."
    kind delete cluster --name $kind_cluster_name
}

function Create_Cluster () {
echo "CREATING KIND CLUSTER..."
cat <<EOF | kind create cluster --name $kind_cluster_name --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
    image: kindest/node:$k8s_version
  - role: worker
    image: kindest/node:$k8s_version
    extraMounts:
      - hostPath: $host_path
        containerPath: $container_path
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
  - role: worker
    image: kindest/node:$k8s_version
EOF
}

function install_CNI () {
    echo "------------------------------------------------"
    echo "INSTALLING CALICO CNI"
    echo "------------------------------------------------"
    helm repo add projectcalico https://docs.tigera.io/calico/charts
    helm repo update projectcalico
    local control_plane_ip
    control_plane_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
      "${kind_cluster_name}-control-plane")

    # Calico 3.32 ships CRDs in a separate chart; install them before the operator.
    helm template calico-crds projectcalico/crd.projectcalico.org.v1 \
      --version "$calico_version" | kubectl apply --server-side -f -

    local helm_attempt=1
    local helm_max_attempts=3
    local helm_install_succeeded=false
    while (( helm_attempt <= helm_max_attempts )); do
      echo "Installing Calico operator (attempt $helm_attempt/$helm_max_attempts)..."
      if helm upgrade --install calico projectcalico/tigera-operator \
        --version "$calico_version" \
        --namespace tigera-operator \
        --create-namespace \
        --set kubernetesServiceEndpoint.host="$control_plane_ip" \
        --set kubernetesServiceEndpoint.port=6443 \
        --set installation.enabled=true \
        --set installation.calicoNetwork.ipPools[0].cidr=10.244.0.0/16 \
        --set installation.calicoNetwork.ipPools[0].encapsulation=VXLAN \
        --set apiServer.enabled=true \
        --set goldmane.enabled=true \
        --set whisker.enabled=true \
        --wait --timeout 5m; then
        helm_install_succeeded=true
        break
      fi

      if (( helm_attempt < helm_max_attempts )); then
        echo "Calico operator installation failed; retrying in 5 seconds..." >&2
        sleep 5
      fi
      ((helm_attempt++))
    done

    if [[ "$helm_install_succeeded" != true ]]; then
      echo "ERROR: Calico Helm installation failed; aborting CNI setup." >&2
      return 1
    fi

    kubectl set env deployment/tigera-operator -n tigera-operator \
      KUBERNETES_SERVICE_HOST="$control_plane_ip" \
      KUBERNETES_SERVICE_PORT=6443

    kubectl rollout status deployment/tigera-operator -n tigera-operator --timeout=120s
    echo "Waiting for Calico resources to be created..."
    local calico_selectors=(calico-node calico-kube-controllers calico-apiserver)
    for selector in "${calico_selectors[@]}"; do
      local calico_timeout=$((SECONDS + 240))  # 4 minutes timeout
      until kubectl get pods -n calico-system -l "k8s-app=$selector" \
        --no-headers 2>/dev/null | grep -q .; do
        if (( SECONDS >= calico_timeout )); then
          echo "Timed out waiting for Calico resources: $selector"
          kubectl get installation default -o yaml 2>/dev/null || true
          return 1
        fi
        sleep 2
      done
    done

    echo "Waiting for calico pods to be ready..."
    kubectl wait --for=condition=ready pod -l k8s-app=calico-kube-controllers -n "calico-system" --timeout=60s
    kubectl wait --for=condition=ready pod -l k8s-app=calico-apiserver -n "calico-system" --timeout=60s
    kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n "calico-system" --timeout=60s
    kubectl wait --for=condition=Ready nodes --all --timeout=180s
    echo "exporting Calico Whisker port-forward to localhost:8081..."
    kubectl port-forward service/whisker 8081 -n calico-system >/dev/null 2>&1 &
    
}

function install_metallb () {
    echo "------------------------------------------------"
    echo "INSTALLING METALLB (L2 ADVERTISEMENT)..."
    echo "------------------------------------------------"
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
    kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=120s

    cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.18.255.200-172.18.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-adv
  namespace: metallb-system
EOF
}

function enable_gateway_api () {
  echo "------------------------------------------------"
  echo "ENABLE GATEWAY API CRDS"
  echo "------------------------------------------------"
  # CRDs Oficiais Upstream
  local gateway_api_crds=(
    gateways.gateway.networking.k8s.io
    gatewayclasses.gateway.networking.k8s.io
    httproutes.gateway.networking.k8s.io
    grpcroutes.gateway.networking.k8s.io
    referencegrants.gateway.networking.k8s.io
    backendtlspolicies.gateway.networking.k8s.io
    listenersets.gateway.networking.k8s.io
    tcproutes.gateway.networking.k8s.io
    tlsroutes.gateway.networking.k8s.io
    udproutes.gateway.networking.k8s.io
  )

  local apply_output
  if ! apply_output=$(kubectl apply -f "$work_folder/gateway_api/standard-install.yaml" 2>&1); then
    echo "ERROR: failed to install Gateway API CRDs." >&2
    printf '%s\n' "$apply_output" >&2
    return 1
  fi
  printf '%s\n' "$apply_output"

  echo "Verifying Gateway API CRDs..."

  # Converte a lista para 'crd/<nome>'
  local crd_resources=()
  local crd
  for crd in "${gateway_api_crds[@]}"; do
    crd_resources+=("crd/$crd")
  done

  # Aguarda todos os CRDs de uma só vez
  if ! kubectl wait --for=condition=Established "${crd_resources[@]}" --timeout=30s >/dev/null 2>&1; then
    echo "ERROR: One or more Gateway API CRDs were not established within timeout." >&2
    echo "Available Gateway API CRDs:" >&2
    kubectl get crd -o name | grep -E 'gateway\.networking\.(k8s|x-k8s)\.io' >&2 || echo "  none" >&2
    return 1
  fi

  echo "Gateway API CRDs installed and Established."
}

function install_istio_mesh () {
  echo "------------------------------------------------"
  echo "INSTALLING ISTIO SERVICE MESH (CONTROL PLANE)..."
  echo "------------------------------------------------"
  helm repo add istio https://istio-release.storage.googleapis.com/charts
  helm repo update istio
  helm upgrade --install istio-base istio/base -n istio-system --create-namespace --wait
  helm upgrade --install istiod istio/istiod -n istio-system --set meshConfig.accessLogFile=/dev/stdout --wait
  
  kubectl label namespace default istio-injection=enabled --overwrite
  #kubectl apply -f "$work_folder/calico-route.yaml"
}

function install_kiali () {

  echo "INSTALLING KIALI DASHBOARD..."
  helm upgrade --install \
    --namespace istio-system \
    --set auth.strategy="anonymous" \
    --repo https://kiali.org/helm-charts \
    kiali-server \
    kiali-server
  kubectl apply -f $work_folder/istio/kiali-configmap.yaml
  kubectl apply -f $work_folder/istio/istio-telemetry.yaml
  kubectl apply -f $work_folder/istio/kiali-route.yaml
  kubectl rollout restart deployment kiali -n istio-system
}

function dash_headlamp () {
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/headlamp/main/kubernetes-headlamp.yaml
  kubectl -n kube-system create serviceaccount headlamp-admin
  kubectl create clusterrolebinding headlamp-admin --serviceaccount=kube-system:headlamp-admin --clusterrole=cluster-admin
  sleep 10
  kubectl apply -f $work_folder/headlamp/route.yaml
  
}
function token_headlamp () {
  echo "------------------------------------------------"
  echo "TOKEN TO ACCESS HEADLAMP"
  kubectl create token headlamp-admin -n kube-system
  echo ""
  echo "------------------------------------------------"
  
}


function deploy_gateway_api_instance () {
    echo "DEPLOYING ISTIO GATEWAY INSTANCE..."
    cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-gateway
  namespace: istio-system
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
EOF

echo "Waiting for Gateway Deployment to be created..."
    # Espera o Deployment aparecer antes de patchear
    until kubectl get deployment istio-gateway-istio -n istio-system &> /dev/null; do
      sleep 2
    done

    echo "APPLYING INFRASTRUCTURE PATCHES (HostNetwork + DNS + NodeSelector)..."
    
    # PATCH UNIFICADO: 
    # 1. Remove sysctls (evita erro de porta privilegiada no HostNetwork)
    # 2. Ativa hostNetwork (conecta ao localhost do Windows)
    # 3. Ajusta dnsPolicy (mantém o DNS interno do K8s funcional)
    # 4. Fixa no nó ha-worker (onde a porta 80 está aberta no Kind)
    
    kubectl patch deployment istio-gateway-istio -n istio-system --type=json -p='[
      {"op": "remove", "path": "/spec/template/spec/securityContext/sysctls"},
      {"op": "replace", "path": "/spec/template/spec/hostNetwork", "value": true},
      {"op": "replace", "path": "/spec/template/spec/dnsPolicy", "value": "ClusterFirstWithHostNet"},
      {"op": "replace", "path": "/spec/template/spec/nodeSelector", "value": {"ingress-ready": "true"}}
    ]'

    echo "Waiting for Gateway to be Ready..."
    kubectl rollout status deployment istio-gateway-istio -n istio-system --timeout=90s
}



function prometheus () {
  echo "------------------------------------------------"
  echo "INSTALLING Prometheus"
  echo "------------------------------------------------"
  echo "Installing Prometheus..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update prometheus-community
  helm upgrade --install prometheus prometheus-community/prometheus --namespace prometheus --create-namespace
  kubectl apply -f $work_folder/prometheus/prometheus-route.yaml
}

function grafana () {
  echo "------------------------------------------------"
  echo "INSTALLING GRAFANA (WITH RETRY)"
  echo "------------------------------------------------"
  
  helm repo add grafana https://grafana-community.github.io/helm-charts
  helm repo update grafana

  local max_attempts=3
  local attempt=1
  local success=false

  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt of $max_attempts: Installing Grafana..."
    
    
    if helm upgrade --install grafana grafana/grafana \
      --namespace grafana --create-namespace \
      -f "$work_folder/grafana/grafana-values.yaml" \
      --wait --timeout 5m; then
      
      success=true
      break
    else
      echo "⚠️ TLS Handshake or Download failed. Retrying in 10 seconds..."
      sleep 10
      ((attempt++))
    fi
  done

  if [ "$success" = true ]; then
    echo "✅ Grafana installed successfully!"
    kubectl apply -f "$work_folder/grafana/grafana-route.yaml"
    get_grafana_token
  else
    echo "❌ Failed to install Grafana after $max_attempts attempts."
    return 1
  fi
}

function get_grafana_token () {
  {
    echo "------------------------------------------------"
    echo "TOKEN TO ACCESS GRAFANA"
    kubectl get secret -n grafana grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
    echo ""
    echo "------------------------------------------------"
  } | tee ~/token.txt
}

function deploy_pycrud () {

  echo "------------------------------------------------"
  echo "deploy pycryud application"
  #kubectl apply -f /home/hodor/study/DevOps/Python/pycrud/k8s/
  kubectl create ns dev --dry-run=client -o yaml | kubectl label -f - istio-injection=enabled --local -o yaml | kubectl annotate -f - your-annotation-key="your-annotation-value" --local -o yaml | kubectl apply -f -
  helm repo add pycrud https://doug2901.github.io/pycrud/
  helm repo update pycrud
  helm upgrade --install pycrud pycrud/pycrud --namespace dev --create-namespace --wait
  echo ""
  echo "------------------------------------------------"

}

function deploy_argocd () {

  echo "------------------------------------------------"
  echo "deploy argocd application"
  kubectl apply -f $work_folder/argocd/1-namespace.yaml
  kubectl apply -k $work_folder/argocd/
  kubectl patch configmap argocd-cmd-params-cm -n argocd \
    --type merge --patch '{"data":{"server.insecure":"true"}}'
  kubectl rollout restart deployment/argocd-server -n argocd

  # 2. Espera o Repo Server (Gerador de manifestos)
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-repo-server -n argocd --timeout=90s

  # 3. Espera o Dex Server (Autenticação)
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-dex-server -n argocd --timeout=90s

  # 4. Espera o Servidor Principal (API e UI)
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=90s

  # 5. Espera os Controllers Adicionais
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-applicationset-controller -n argocd --timeout=90s
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-notifications-controller -n argocd --timeout=90s

  kubectl apply -f "$work_folder/argocd/argocd-route.yaml"

  echo "ArgoCD está 100% operacional!"
  echo "ArgoCD URL: http://argocd.lab.corp/"
  echo ""
  echo "------------------------------------------------"
}


function get_argocd_token () {

  echo "------------------------------------------------"
  echo "User to access ArgoCD: admin"
  echo "Password to access ArgoCD:"
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  echo ""
  echo "------------------------------------------------"

}


function port_foward() {

  #kubectl port-forward service/argocd-server 8070:443 -n argocd >/dev/null 2>&1 &
  kubectl port-forward service/whisker 8081 -n calico-system >/dev/null 2>&1 &

}

function crossplane() {

  helm repo add crossplane-stable https://charts.crossplane.io/stable
  helm repo update crossplane-stable
  helm upgrade --install crossplane crossplane-stable/crossplane --namespace crossplane-system --create-namespace

}



case "${1:-}" in
    del)
        Delete_Cluster
        ;;
    basic)
        Delete_Cluster
        Create_Cluster
        install_CNI
        install_metallb
        enable_gateway_api
        ;;
    base)
        Delete_Cluster
        Create_Cluster
        install_CNI
        install_metallb
        enable_gateway_api
        install_istio_mesh
        deploy_gateway_api_instance
        dash_headlamp
        token_headlamp
        ;;
    o11y)
        prometheus
        grafana
        get_grafana_token
        install_kiali
        ;;
    token)
        token_headlamp
        get_grafana_token
        get_argocd_token
        ;;
    app)
        deploy_pycrud
        ;;
    argocd)
        deploy_argocd
        get_argocd_token
        ;;
    port)
        port_foward
        ;;
    crossplane)
        crossplane
        ;;
    all)
        Delete_Cluster
        Create_Cluster
        install_CNI
        install_metallb
        enable_gateway_api
        install_istio_mesh
        deploy_gateway_api_instance
        dash_headlamp
        prometheus
        grafana
        install_kiali
        deploy_pycrud
        deploy_argocd
        crossplane
        token_headlamp
        get_grafana_token
        get_argocd_token
        ;;
    *)  
        cat <<EOF
Usage: $0 [del|base|basic|all|o11y|grafana|prometheus|token|app]"
------------------------------------------------
del    -> delete kind cluster '${kind_cluster_name}'
base  -> delete kind cluster '${kind_cluster_name}' + create cluster + install calico + metallb + gateway api + istio + headlamp dashboard
basic  -> delete kind cluster '${kind_cluster_name}' + create cluster + install calico + metallb + gateway api 
o11y   -> install grafana + prometheus
app  -> deploy pycrud application
argocd  -> deploy argocd application
crossplane -> install crossplane
token  -> print grafana and headlamp tokens
all  -> install everything above
------------------------------------------------
EOF
        exit 1
        ;;
esac

end_time=$(date +%s)
elapsed=$((end_time - start_time))
echo "------------------------------------------------"
echo "✅ PROCESSO CONCLUÍDO EM: $((elapsed / 60))m $((elapsed % 60))s"
echo "------------------------------------------------"
