# Kubernetes local

Este repositório reúne configurações e manifests para um ambiente Kubernetes
local baseado em [Kind](https://kind.sigs.k8s.io/).

## Cluster Kind

Consulte o guia completo para instalar e configurar o cluster:

➡️ [Guia de criação do cluster Kind](./kind/README.md)

O guia inclui:

- pré-requisitos;
- criação do cluster e configuração dos nós;
- instalação de Calico, MetalLB, Gateway API e Istio;
- instalação opcional de Headlamp, Prometheus, Grafana, Kiali, Argo CD e
  Crossplane;
- configuração dos acessos locais;
- geração de certificados;
- instalação do Metrics Server;
- remoção do cluster.
