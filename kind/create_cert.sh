#!/bin/bash
# 1. Crie a chave e o certificado da Autoridade Certificadora (CA)
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.pem -subj "/CN=My-Lab-CA"

# 2. Crie uma chave privada para o domínio k8sdash.lab.corp
openssl genrsa -out k8sdash.lab.corp.key 2048

# 3. Crie uma Certificate Signing Request (CSR)
openssl req -new -key k8sdash.lab.corp.key -out k8sdash.lab.corp.csr -subj "/CN=k8sdash.lab.corp"

# 4. Assine o certificado com a CA e adicione Subject Alternative Names (SANs)
# SANs são cruciais para que navegadores e o curl não deem erro de hostname mismatch.
openssl x509 -req -days 365 -in k8sdash.lab.corp.csr \
    -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out k8sdash.lab.corp.crt \
    -extfile <(printf "subjectAltName=DNS:k8sdash.lab.corp,IP:127.0.0.1")
