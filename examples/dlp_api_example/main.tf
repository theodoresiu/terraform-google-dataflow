provider "google" {
  region  = "${var.region}"
}

locals {
  gcs_bucket_name = "tmp-dir-bucket-${random_id.random_suffix.hex}"
}


module "dataflow-bucket" {
  source = "../../modules/dataflow_bucket"
  name   = "${local.gcs_bucket_name}"
  region = "${var.region}"
  project_id    = "${var.project_id}"
}


resource "null_resource" "download_sample_cc_into_gcs"{
  provisioner "local-exec" {
    command = <<EOF
    curl http://eforexcel.com/wp/wp-content/uploads/2017/07/1500000%20CC%20Records.zip > cc_records.zip
    unzip cc_records.zip
    rm cc_records.zip 
    mv 1500000\ CC\ Records.csv cc_records.csv
    gsutil cp cc_records.csv gs://${module.dataflow-bucket.name}
    rm cc_records.csv
    EOF
    }
}



resource "null_resource" "deinspection_template_setup"{
  provisioner "local-exec" {
    command = <<EOF
    if [ -f wrapped_key.txt ] && [ ${null_resource.create_kms_wrapped_key.count}=1 ]; then
      wrapped_key=$(cat wrapped_key.txt)
    else
      wrapped_key=${var.wrapped_key}
    fi

    echo $wrapped_key

    curl https://dlp.googleapis.com/v2/projects/${var.gcp_project}/deidentifyTemplates -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
    -H "Content-Type: application/json" \
    -d '{"deidentifyTemplate": {"deidentifyConfig": {"recordTransformations": {"fieldTransformations": [{"fields": [{"name": "Card Number"}, {"name": "Card PIN"}], "primitiveTransformation": {"cryptoReplaceFfxFpeConfig": {"cryptoKey": {"kmsWrapped": {"cryptoKeyName": "projects/${var.gcp_project}/locations/global/keyRings/${var.key_ring}/cryptoKeys/${var.kms_key_name}", "wrappedKey": "'$wrapped_key'"}}, "commonAlphabet": "ALPHA_NUMERIC"}}}]}}}, "templateId": "15"}'
    EOF
    }
}

resource "google_bigquery_dataset" "default" {
  project                     = "${var.project_id}"
  dataset_id                  = "dlp_demo"
  friendly_name               = "dlp_demo"
  description                 = "This is the BQ dataset for running the dlp demo"
  location                    = "US"
  default_table_expiration_ms = 3600000
}


resource "google_kms_key_ring" "create_kms_ring" {
  project = "${var.project_id}"
  count =   "${var.create_key_ring == true ? 1 : 0}"
  name     = "${var.key_ring}"
  location = "global"
}

resource "google_kms_crypto_key" "create_kms_key" {
  project = "${var.project_id}"
  count  = "${google_kms_key_ring.create_kms_ring.count}"
  name =  "${var.kms_key_name}"
  key_ring = "${google_kms_key_ring.create_kms_ring.self_link}"
}


resource "null_resource" "create_kms_wrapped_key"{
  count = "${google_kms_crypto_key.create_kms_key.count}"
  provisioner "local-exec" {
  command=<<EOF
  rm original_key.txt
  rm wrapped_key.txt
  python -c "import os,base64; key=os.urandom(32); encoded_key = base64.b64encode(key).decode('utf-8'); print(encoded_key)" >> original_key.txt
  original_key="$(cat original_key.txt)"
  gcloud kms keys add-iam-policy-binding ${var.kms_key_name} --location global --keyring ${var.key_ring} --member allAuthenticatedUsers --role roles/cloudkms.cryptoKeyEncrypterDecrypter
  curl -s -X POST "https://cloudkms.googleapis.com/v1/projects/${var.gcp_project}/locations/global/keyRings/${var.key_ring}/cryptoKeys/${var.kms_key_name}:encrypt"  -d '{"plaintext":"'$original_key'"}'  -H "Authorization:Bearer $(gcloud auth application-default print-access-token)"  -H "Content-Type:application/json" | python -c "import sys, json; print(json.load(sys.stdin)['ciphertext'])" >> wrapped_key.txt
  EOF
  }


}

resource "google_dataflow_job" "dlp_deidentify_job_to_bigquery" {
    name = "dataflow-dlp-job"
    depends_on = ["null_resource.deinspection_template_setup", "null_resource.download_sample_cc_into_gcs"]
    template_gcs_path = "gs://dataflow-templates/latest/Stream_DLP_GCS_Text_to_BigQuery"
    temp_gcs_location = "gs://${google_storage_bucket.cc_store.name}/tmp_dir"
    project = "${var.gcp_project}"
    parameters = {
    	inputFilePattern="gs://${google_storage_bucket.cc_store.name}/cc_records.csv"
        datasetName = "${google_bigquery_dataset.default.dataset_id}"
        batchSize = 1000
	dlpProjectId ="${var.gcp_project}"
	deidentifyTemplateName="projects/${var.gcp_project}/deidentifyTemplates/15"
    }
}

module "dataflow-job" {
  source                = "../../"
  project_id            = "${var.project_id}"
  name              = "dlp-terraform-example"
  depends_on = ["null_resource.deinspection_template_setup", "null_resource.download_sample_cc_into_gcs"]
  on_delete             = "cancel"
  zone                  = "${var.region}-a"
  template_gcs_path     = "gs://dataflow-templates/latest/Stream_DLP_GCS_Text_to_BigQuery"
  temp_gcs_location     = "${module.dataflow-bucket.name}"
  service_account_email = "${var.service_account_email}"

  parameters = {
    inputFilePattern="gs://${module.dataflow-bucket.name}/cc_records.csv"
    datasetName = "${google_bigquery_dataset.default.dataset_id}"
    batchSize = 1000
    dlpProjectId ="${var.gcp_project}"
    deidentifyTemplateName="projects/${var.gcp_project}/deidentifyTemplates/15"
  }
}