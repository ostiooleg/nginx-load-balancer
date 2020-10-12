provider "hcloud" {
  token = var.hcloud_token
}

provider "aws" {
  region     = "us-west-1"
  access_key = var.access_key
  secret_key = var.secret_key
}

resource "hcloud_ssh_key" "my_ssh_key" {
  name       = "ostio-ssh-key"
  public_key = var.my_ssh_key
}

data "hcloud_ssh_key" "rebrain_ssh_key" {
  name = "REBRAIN.SSH.PUB.KEY"
}

resource "random_password" "password" {
  count            = var.nodes_number
  length           = 10
  special          = true
  override_special = "_%@"
}

resource "hcloud_server" "lb" {
  count       = var.lb_number
  server_type = "cx11"
  name        = "${split(", ", element(var.lb_hosts, count.index))[0]}.${data.aws_route53_zone.devops.name}"
  image       = "centos-8"
  location    = "hel1"
  ssh_keys    = [hcloud_ssh_key.my_ssh_key.id, data.hcloud_ssh_key.rebrain_ssh_key.id]
  user_data   = random_password.password[count.index].result
  labels      = {
    module = "devops"
    email  = "ostioolegg_at_gmail_com"
    number = "${count.index +1}"
  }
  provisioner "remote-exec" {
    inline = [
      "echo ${var.user}:${random_password.password[count.index].result} | chpasswd",
    ]
    connection {
      type        = "ssh"
      user        = "root"
      host        = self.ipv4_address
      private_key = file(var.private_ssh_key)
      timeout     = "2m"
    }
  }
}

resource "hcloud_server" "app" {
  count       = var.app_number
  server_type = "cx11"
  name        = "${split(", ", element(var.app_hosts, count.index))[0]}.${data.aws_route53_zone.devops.name}"
  image       = "centos-8"
  location    = "hel1"
  ssh_keys    = [hcloud_ssh_key.my_ssh_key.id, data.hcloud_ssh_key.rebrain_ssh_key.id]
  user_data   = random_password.password[count.index +1].result
  labels      = {
    module = "devops"
    email  = "ostioolegg_at_gmail_com"
    number = "${count.index +1}"
  }
  provisioner "remote-exec" {
    inline = [
      "echo ${var.user}:${random_password.password[count.index +1].result} | chpasswd",
    ]
    connection {
      type        = "ssh"
      user        = "root"
      host        = self.ipv4_address
      private_key = file(var.private_ssh_key)
      timeout     = "2m"
    }
  }
}

data "aws_route53_zone" "devops" {
  name = "devops.rebrain.srwx.net."
}

resource "aws_route53_record" "lb" {
  count   = var.lb_number
  zone_id = data.aws_route53_zone.devops.zone_id
  name    = "${split(", ", element(var.lb_hosts, count.index))[0]}.${data.aws_route53_zone.devops.name}"
  type    = "A"
  ttl     = "30"
  records = [hcloud_server.lb[count.index].ipv4_address]
}

resource "aws_route53_record" "app" {
  count   = var.app_number
  zone_id = data.aws_route53_zone.devops.zone_id
  name    = "${split(", ", element(var.app_hosts, count.index))[0]}.${data.aws_route53_zone.devops.name}"
  type    = "A"
  ttl     = "30"
  records = [hcloud_server.app[count.index].ipv4_address]
}

resource "aws_route53_record" "domains" {
  count   = var.domains_number
  zone_id = data.aws_route53_zone.devops.zone_id
  name    = "${split(", ", element(var.domains, count.index))[0]}.${data.aws_route53_zone.devops.name}"
  type    = "A"
  ttl     = "30"
  records = [hcloud_server.lb[count.index].ipv4_address]
}

output "public_LB_IPs" {
  value = hcloud_server.lb.*.ipv4_address
}

output "public_APP_IPs" {
  value = hcloud_server.app.*.ipv4_address
}

output "root_passwords" {
  value = random_password.password.*.result
}

resource "local_file" "final_lb_params" {
  content = join ("\n", formatlist("%s: %s.%s %s %s",
  hcloud_server.lb.*.labels.number,
  "${var.lb_hosts}",
  data.aws_route53_zone.devops.name,
  hcloud_server.lb.*.ipv4_address,
  random_password.password.*.result[0]))
  file_permission = "0644"
  filename = "final_lb_params.txt"
}

resource "local_file" "final_app_params" {
  content = join ("\n", formatlist("%s: %s.%s %s %s",
  hcloud_server.app.*.labels.number,
  "${var.app_hosts}",
  data.aws_route53_zone.devops.name,
  hcloud_server.app.*.ipv4_address,
  random_password.password.*.result[1]))
  file_permission = "0644"
  filename = "final_app_params.txt"
}

data "template_file" "ansible_inventory" {
  template = "${file("inventory.tmpl")}"
  vars = {
    lb_hostname = join("\n",hcloud_server.lb.*.ipv4_address)
    app_hostname = join("\n",hcloud_server.app.*.ipv4_address)
  }
}

resource "local_file" "ansible_inventory" {
  content  = data.template_file.ansible_inventory.rendered
  file_permission = "0644"
  filename = "hosts"
  provisioner "local-exec" {
    command = "ansible-playbook -i hosts playbook.yml"
  }
}

