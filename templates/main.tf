# Provisions a Cloudflare Zero Trust tunnel, ingress routing, and DNS records for the fleet.
terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_account_id" {
  type = string
}

variable "cloudflare_zone_id" {
  type = string
}

variable "tunnel_name" {
  type    = string
  default = "TUNNEL_NAME_PLACEHOLDER"
}

variable "tunnel_domain" {
  type    = string
  default = "TUNNEL_DOMAIN_PLACEHOLDER"
}

variable "vip_address" {
  type    = string
  default = "VIP_ADDRESS_PLACEHOLDER"
}

variable "ingress_origin_address" {
  type    = string
  default = "INGRESS_ORIGIN_ADDRESS_PLACEHOLDER"
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

resource "random_password" "tunnel_secret" {
  length = 64
}

# Creates the Zero Trust tunnel in the Cloudflare account.
resource "cloudflare_tunnel" "fleet_ingress" {
  account_id = var.cloudflare_account_id
  name       = var.tunnel_name
  secret     = base64sha256(random_password.tunnel_secret.result)
  config_src = "cloudflare"
}

# Routes tunnel traffic to the connector-local ingress origin. App routes
# behind that ingress may still target a separate service/application VIP.
resource "cloudflare_tunnel_config" "fleet_ingress_config" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_tunnel.fleet_ingress.id

  config {
    ingress_rule {
      hostname = "*.${var.tunnel_domain}"
      service  = "http://${var.ingress_origin_address}:80"
    }

    ingress_rule {
      hostname = var.tunnel_domain
      service  = "http://${var.ingress_origin_address}:80"
    }

    ingress_rule {
      service = "http_status:404"
    }
  }
}

# Points all subdomains to the tunnel.
resource "cloudflare_record" "wildcard_cname" {
  zone_id         = var.cloudflare_zone_id
  name            = "*"
  content         = "${cloudflare_tunnel.fleet_ingress.id}.cfargotunnel.com"
  type            = "CNAME"
  proxied         = true
  allow_overwrite = true
}

# Points the apex domain to the tunnel.
resource "cloudflare_record" "root_cname" {
  zone_id         = var.cloudflare_zone_id
  name            = "@"
  content         = "${cloudflare_tunnel.fleet_ingress.id}.cfargotunnel.com"
  type            = "CNAME"
  proxied         = true
  allow_overwrite = true
}

output "tunnel_token" {
  value     = cloudflare_tunnel.fleet_ingress.tunnel_token
  sensitive = true
}

output "tunnel_id" {
  value = cloudflare_tunnel.fleet_ingress.id
}

output "tunnel_name" {
  value = cloudflare_tunnel.fleet_ingress.name
}
