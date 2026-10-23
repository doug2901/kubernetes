# Cluster local com Kind

Este diretório contém o script para criar um cluster Kubernetes local usando
[Kind](https://kind.sigs.k8s.io/). O cluster é criado com três nós, Calico
como CNI, MetalLB, Gateway API e Istio. Componentes adicionais, como
Headlamp, Prometheus, Grafana, Kiali, Argo CD, a aplicação `pycrud` e
Crossplane, podem ser instalados pelo próprio script.

## Pré-requisitos

Instale e deixe disponíveis no `PATH`:

- Docker em execução;
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation);
- `kubectl`;
- Helm 3;
- OpenSSL, caso os certificados locais sejam necessários.

O script usa `~/postgres` como diretório do host montado no worker do Kind.
Crie-o antes da criação do cluster:

```bash
mkdir -p "$HOME/postgres"
```

## Criação do cluster

Execute os comandos a partir deste diretório, pois o script usa caminhos
relativos para os manifests:

```bash
cd kind
chmod +x create_cluster.sh
./create_cluster.sh base
```

O cluster criado se chama `my-lab` e usa a imagem
`kindest/node:v1.37.0`. A configuração possui:

- um nó `control-plane`;
- dois nós `worker`;
- CNI padrão do Kind desabilitado;
- Calico `v3.32.2`, com pool `10.244.0.0/16` e encapsulamento VXLAN;
- um worker marcado com `ingress-ready=true`;
- portas `80` e `443` do worker publicadas no host;
- o caminho `~/postgres` do host montado em `/mnt/data/postgres`.

Verifique o resultado:

```bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
```

## Modos disponíveis

Os modos `basic`, `base` e `all` recriam o cluster. Os demais modos instalam
componentes sobre um cluster existente, com exceção de `del`, que apenas o
remove.

| Comando | O que faz |
| --- | --- |
| `./create_cluster.sh basic` | Remove o cluster anterior, cria o cluster, instala Calico, MetalLB e Gateway API. |
| `./create_cluster.sh base` | Executa `basic`, instala Istio, cria o Gateway Istio e instala o Headlamp. |
| `./create_cluster.sh o11y` | Instala Prometheus, Grafana e Kiali. Requer um cluster já criado. |
| `./create_cluster.sh app` | Cria o namespace `dev` com injeção Istio e instala a aplicação `pycrud` via Helm. |
| `./create_cluster.sh argocd` | Instala o Argo CD, configura o servidor em HTTP e publica sua rota. |
| `./create_cluster.sh crossplane` | Instala o Crossplane via Helm. |
| `./create_cluster.sh token` | Exibe os tokens/senhas do Headlamp, Grafana e Argo CD. |
| `./create_cluster.sh port` | Inicia um port-forward do Whisker na porta local `8081`. |
| `./create_cluster.sh all` | Recria o cluster e instala todos os componentes acima. |
| `./create_cluster.sh del` | Remove o cluster `my-lab`. |

Uma sequência comum para um ambiente completo é:

```bash
./create_cluster.sh all
./create_cluster.sh token
```

O modo `all` pode demorar alguns minutos, pois aguarda os deployments e pods
ficarem prontos e faz novas tentativas em algumas instalações Helm.

## Acessos locais

O Gateway do Istio usa `hostNetwork`, é fixado no worker com o label
`ingress-ready=true` e escuta HTTP na porta `80`. Para usar os nomes das rotas que são aplicadas pelo script, adicione estas
entradas ao arquivo `/etc/hosts`:

```text
127.0.0.1 argocd.lab.corp
127.0.0.1 grafana.lab.corp
127.0.0.1 k8sdash.lab.corp
127.0.0.1 kiali.lab.corp
127.0.0.1 prometheus.lab.corp
```

O hostname configurado para o Headlamp é `k8sdash.lab.corp`.

Depois de instalar cada componente, os endpoints são:

| Serviço | URL | Observação |
| --- | --- | --- |
| Headlamp | <http://k8sdash.lab.corp/> | Token exibido por `./create_cluster.sh token`. |
| Prometheus | <http://prometheus.lab.corp/> | Disponível após `o11y` ou `all`. |
| Grafana | <http://grafana.lab.corp/> | Disponível após `o11y` ou `all`; senha exibida por `token`; usuário padrão do chart: `admin`. |
| Kiali | <http://kiali.lab.corp/> | Disponível após `o11y` ou `all`; autenticação anônima conforme o script. |
| Argo CD | <http://argocd.lab.corp/> | Disponível após `argocd` ou `all`; usuário `admin`. |

O Whisker, dashboard do Calico, também pode ser acessado por:

```bash
./create_cluster.sh port
# http://127.0.0.1:8081
```

O `port-forward` é iniciado em segundo plano. Para localizar e encerrar o
processo posteriormente, use as ferramentas de processos do seu sistema.

## Certificado local

O script `create_cert.sh` cria uma CA local e um certificado para
`k8sdash.lab.corp`, incluindo SAN para `127.0.0.1`:

```bash
chmod +x create_cert.sh
./create_cert.sh
```

Os arquivos gerados são `ca.key`, `ca.pem`, `ca.srl`,
`k8sdash.lab.corp.key`, `k8sdash.lab.corp.csr` e `k8sdash.lab.corp.crt`.
A CA (`ca.pem`) precisa ser confiada pelo sistema ou navegador antes de o
certificado ser aceito sem avisos.

Atualmente, o Gateway criado por `create_cluster.sh` possui apenas um listener
HTTP na porta `80`. Portanto, a geração do certificado não habilita HTTPS
automaticamente; é necessário configurar um listener TLS e um Secret
Kubernetes para usá-lo.

## Métricas do Kubernetes

O arquivo [`metrics.yaml`](./metrics.yaml) contém uma instalação do
Metrics Server (`v0.7.2`) configurada para o ambiente local, incluindo
`--kubelet-insecure-tls`. Ele não é aplicado automaticamente por nenhum modo
do script. Para instalá-lo explicitamente:

```bash
kubectl apply -f metrics.yaml
kubectl top nodes
kubectl top pods -A
```

## Remoção

Para remover o cluster:

```bash
./create_cluster.sh del
```

Essa operação remove os containers e os recursos do Kind associados ao
cluster `my-lab`. O diretório `~/postgres` é um caminho do host e não é
removido pelo script.

## Estrutura relevante

- `create_cluster.sh`: criação do cluster e instalação dos componentes;
- `create_cert.sh`: geração da CA e do certificado local;
- `gateway_api/`: CRDs da Gateway API;
- `argocd/`, `grafana/`, `headlamp/`, `istio/` e `prometheus/`: rotas e
  configurações dos serviços;
- `calico-route.yaml`: rota e política de rede do Whisker;
- `metrics.yaml`: manifest do Metrics Server.
