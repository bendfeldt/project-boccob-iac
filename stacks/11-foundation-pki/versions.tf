terraform {
  required_version = "~> 1.13.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "5.13.0"
    }
  }
}
