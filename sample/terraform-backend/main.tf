terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.50.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# 1. サーバーレスVPCアクセスコネクタ
resource "google_vpc_access_connector" "connector" {
  name  = "intern-connector"
  ip_cidr_range = "10.8.0.0/28"
  network       = "default"     # 接続先のVPCネットワークも指定するのが一般的です
  region        = var.region
}

# 2. Cloud Run用のサービスアカウント
resource "google_service_account" "run_sa" {
  account_id   = "cloudrun-sql-accessor"
  display_name = "Cloud Run SQL Accessor"
}

# サービスアカウントに必要な権限を付与
resource "google_project_iam_member" "sql_client_role" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

# Secret Managerに作成済みのシークレットの情報を参照
data "google_secret_manager_secret" "db_password_secret" {
  secret_id = "intern-db-password"
}

# Cloud Runが使用するサービスアカウントに、特定のシークレットへのアクセス権を付与
resource "google_secret_manager_secret_iam_member" "secret_accessor_role" {
  project   = data.google_secret_manager_secret.db_password_secret.project
  secret_id = data.google_secret_manager_secret.db_password_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run_sa.email}"
}

# 3. Cloud Runサービス
resource "google_cloud_run_v2_service" "backend_service" {
  name     = "backend-service"
  location = var.region
  
  template {
    service_account = google_service_account.run_sa.email
    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "PRIVATE_RANGES_ONLY"
    }
    containers {
      image = "gcr.io/${var.project_id}/intern-app-backend:v2"
      env {
        name  = "INSTANCE_CONNECTION_NAME"
        value = var.instance_connection_name
      }
      env {
        name  = "DB_NAME"
        value = var.db_name
      }
      env {
        name  = "DB_USER"
        value = var.db_user
      }
      env {
        name = "DB_PASS"
        value_source {
          secret_key_ref {
            secret  = var.db_pass
            version = "latest"
          }
        }
      }
    }
  }
  
  # Ingress設定と認証設定もコードで定義
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  launch_stage = "GA"

  traffic {
    percent         = 100
    type            = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
  }

  depends_on = [
    google_project_iam_member.sql_client_role,
    google_secret_manager_secret_iam_member.secret_accessor_role
  ]
}