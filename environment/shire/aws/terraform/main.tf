/* Written by: Jonathan Johnson
Resources:
Terraform Docs: https://www.terraform.io/docs/index.html
Chris Long's Terraform Lab: https://github.com/clong/DetectionLab/tree/master/Terraform
*/
# Provide Region
provider "aws" {
region                  = var.region
}

# Inital VPC 
resource "aws_vpc" "default" {
  cidr_block = "172.18.0.0/16"
}

# Internet Gateway creation
resource "aws_internet_gateway" "default" {
  vpc_id = aws_vpc.default.id
}

# Route table to give VPC internet
resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.default.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.default.id
}

# subnet creation
resource "aws_subnet" "default" {
  vpc_id                  = aws_vpc.default.id
  cidr_block              = "172.18.39.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
}


resource "aws_vpc_dhcp_options" "default" {
  domain_name          = "shire.com"
  domain_name_servers  = concat([aws_instance.dc.private_ip], var.external_dns_servers)
  netbios_name_servers = [aws_instance.dc.private_ip]
 }

resource "aws_vpc_dhcp_options_association" "default" {
  vpc_id          = aws_vpc.default.id
  dhcp_options_id = aws_vpc_dhcp_options.default.id
}

# Security Group for Linux Machines
resource "aws_security_group" "linux" {
  name        = "linux_security_group"
  description = "Mordor: Security Group for the Linux Hosts"
  vpc_id	= aws_vpc.default.id

  # SSH Access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ip_whitelist
  }

  # Apache Guacamole Access
  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = var.ip_whitelist
  }

    # Apache Spark Access
  ingress {
    from_port   = 8088
    to_port     = 8088
    protocol    = "tcp"
    cidr_blocks = var.ip_whitelist
  }

    # Kibana Access
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.ip_whitelist
  }

  # private subnet
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["172.18.39.0/24"]
  }

  # Connect to Internet Gateway - internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "windows" {
  name        = "mordor_windows_workstations"
  description = "Security Group for Mordor Windows Machines"
  vpc_id      = aws_vpc.default.id

  # RDP
  ingress {
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = var.ip_whitelist
  }

  # WinRM
  ingress {
    from_port   = 5985
    to_port     = 5986
    protocol    = "tcp"
    cidr_blocks = var.ip_whitelist
  }


  # private subnet
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["172.18.39.0/24"]
  }

  # Connect to Internet Gateway - internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "auth" {
  key_name   = var.public_key_name
  public_key = file(var.public_key_path)
}

/*
Apache Guacamole
This process will call a community ami and build out the Apache Gaucamole Service through a scipt provided: https://github.com/jsecurity101/ApacheGuacamole.
Changes were made to fit the lab's requirements. 

The Provisioning process will update the system, add github, add a user with a password, add that user to sudoers file, then
update the sshd_config file to allow Password Authentication. User has option to login with ssh keys or user's password
*/
resource "aws_instance" "guac" {
  instance_type = "t2.medium"
  ami           = coalesce(data.aws_ami.guac_ami.image_id, var.guac_ami)

  tags = {
    Name = "Apache-Guacamole"
  }

  subnet_id              = aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.linux.id]
  key_name               = aws_key_pair.auth.key_name
  private_ip             = "172.18.39.9"

  provisioner "file" {
    source          = "../scripts/ApacheGuacamole/user-mapping.xml"
    destination     = "user-mapping.xml"
  

connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }
provisioner "file" {
    source          = "../scripts/ApacheGuacamole/sshd_config"
    destination     = "sshd_config"
  
connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get intall git -y",
      "sudo adduser --disabled-password --gecos \"\" guac && echo 'guac:guac' | sudo chpasswd",
      "sudo mkdir /home/guac/.ssh && sudo cp /home/ubuntu/.ssh/authorized_keys /home/guac/.ssh/authorized_keys && sudo chown -R guac:guac /home/guac/.ssh",
      "echo 'guac   ALL=(ALL:ALL) NOPASSWD:ALL' | sudo tee -a /etc/sudoers",
      "sudo git clone https://github.com/jsecurity101/ApacheGuacamole.git",
      "cd ApacheGuacamole",
      "sudo bash ApacheGuacamole.sh",
      "cd ..",
      "sudo mv ~/user-mapping.xml /etc/guacamole/user-mapping.xml",
      "sudo mv ~/sshd_config /etc/ssh/sshd_config",
      "sudo service sshd restart",
      "sudo service tomcat7 restart",
      "sudo /usr/bin/guacd &<<EOF",
      " ",
      "EOF",
    ]
      connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }
  root_block_device {
    delete_on_termination = true
    volume_size           = 100
  }
}



/*
Empire
This process will call a community ami and build out the Empire C2 Framework: https://github.com/EmpireProject/Empire.
Empire can be found in the /opt/ folder. 

The Provisioning process will update the system, add github, add a user with a password, add that user to sudoers file, then
update the sshd_config file to allow Password Authentication. User has option to login with ssh keys or user's password
*/
resource "aws_instance" "empire" {
instance_type = "t2.medium"
ami           = coalesce(data.aws_ami.empire_ami.image_id, var.empire_ami)

  tags = {
   Name = "Empire"
  }

  subnet_id              = aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.linux.id]
  key_name               = aws_key_pair.auth.key_name
  private_ip             = "172.18.39.8"

  provisioner "file" {
    source          = "../scripts/Empire/sshd_config"
    destination     = "sshd_config"
  

connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }
   provisioner "file" {
    source          = "../scripts/Empire/install_empire.sh"
    destination     = "install_empire.sh"
  

connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }
  # Created User 'wardog'. Copying ssh keys. 
  provisioner "remote-exec" {
    inline = [
    "sudo add-apt-repository universe",
    "sudo adduser --disabled-password --gecos \"\" wardog && echo 'wardog:wardog' | sudo chpasswd",
    "sudo mkdir /home/wardog/.ssh && sudo cp /home/ubuntu/.ssh/authorized_keys /home/wardog/.ssh/authorized_keys && sudo chown -R wardog:wardog /home/wardog/.ssh",
    "echo 'wardog   ALL=(ALL:ALL) NOPASSWD:ALL' | sudo tee -a /etc/sudoers",
    "sudo apt-get update",
    "sudo apt-get install git -y",
    "sudo mv ~/sshd_config /etc/ssh/sshd_config",
    "sudo service sshd restart",
    "sudo git clone https://github.com/EmpireProject/Empire.git /opt/Empire",
    "sudo apt-get install dos2unix",
    "sudo dos2unix install_empire.sh",
    "sudo bash /home/ubuntu/install_empire.sh",
    ]
     connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }
  root_block_device {
   delete_on_termination = true
    volume_size           = 100
  }
}


/*
HELK
This process will call a community ami and build out HELK : https://github.com/Cyb3rWard0g/HELK. 
HELK is installed with option 3: Kafka, KSQL, ELK, NGNIX, Spark, Jupyter.
HELK can be found in the /opt/ folder. 

The Provisioning process will update the system, add github, add a user with a password, add that user to sudoers file, then
update the sshd_config file to allow Password Authentication. User has option to login with ssh keys or user's password
*/
resource "aws_instance" "helk" {
  instance_type = "t2.xlarge"
  ami           = coalesce(data.aws_ami.helk_ami.image_id, var.helk_ami)

  tags = {
    Name = "HELK"
  }

  subnet_id              = aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.linux.id]
  key_name               = aws_key_pair.auth.key_name
  private_ip             = "172.18.39.6"

provisioner "file" {
    source          = "../scripts/HELK/sshd_config"
    destination     = "sshd_config"
  

connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }
  
    provisioner "file" {
    source          = "../scripts/HELK/install_helk.sh"
    destination     = "install_helk.sh"
  

connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }
 
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo adduser --disabled-password --gecos \"\" aragon && echo 'aragon:aragon' | sudo chpasswd",
      "sudo mkdir /home/aragon/.ssh && sudo cp /home/ubuntu/.ssh/authorized_keys /home/aragon/.ssh/authorized_keys && sudo chown -R aragon:aragon /home/aragon/.ssh",
      "echo 'aragon   ALL=(ALL:ALL) NOPASSWD:ALL' | sudo tee -a /etc/sudoers",
      "sudo git clone https://github.com/Cyb3rWard0g/mordor.git /opt/mordor",
      "sudo apt-get install kafkacat -y",
      "sudo mv ~/sshd_config /etc/ssh/sshd_config",
      "sudo service sshd restart",
      "sudo git clone https://github.com/Cyb3rWard0g/HELK.git /opt/HELK",
      "cd /home/ubuntu",
      "sudo apt-get install dos2unix",
      "sudo dos2unix install_helk.sh",
      "sudo bash install_helk.sh",

    ]
      connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }
  root_block_device {
    delete_on_termination = true
    volume_size           = 100
  }
}



/*
HFDC1
This process is going to provision from a Pre-Built AMI.
This AMI already has the forest, GPOs, and Users deployed.
*/
resource "aws_instance" "dc" {
  instance_type = "t2.medium"
ami = coalesce(data.aws_ami.dc_ami.image_id, var.dc_ami)

  tags = {
    Name = "HFDC1.shire.com"
  }

  subnet_id              = aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.windows.id]
  private_ip             = "172.18.39.5"


   provisioner "remote-exec" {
    connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "winrm"
      user        = "Administrator"
      password    = "S@lv@m3!M0d3" 
      insecure    = "true"
      
      
    }
    inline = [
      "powershell set ExecutionPolicy Unrestricted -Force",
      "powershell Remove-Item  C:\\mordor\\ -Force -Recurse",
      "powershell git clone https://github.com/jsecurity101/mordor.git C:\\mordor\\",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\DC\\registry_system_enableula_sacl.ps1",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\DC\\registry_terminal_server_sacl.ps1",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\DC\\import-LOTR.ps1",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\DC\\import_gpo.ps1",
      "powershell gpupdate /Force",
      "powershell Restart-Computer -Force",
    ]
     
  }

  root_block_device {
    delete_on_termination = true
  }
}


/*
WECServer
This process is going to provision from a Pre-Built AMI.
This AMI already has the WEC subscriptions and WEC service deployed.
*/
resource "aws_instance" "wec" {
  instance_type = "t2.medium"
  ami = coalesce(data.aws_ami.wec_ami.image_id, var.wec_ami)

  tags = {
    Name = "WECServer.shire.com"
  }

  subnet_id              = aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.windows.id]
  private_ip             = "172.18.39.102"


    provisioner "remote-exec" {
       connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "winrm"
      user        = "Administrator"
      password    = "S@lv@m3!M0d3" 
      insecure    = "true" 
    }
    inline = [
      "powershell set ExecutionPolicy Unrestricted -Force",
      "powershell Remove-Item  C:\\mordor\\ -Force -Recurse",
      "powershell git clone https://github.com/jsecurity101/mordor.git C:\\mordor",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\WEC\\registry_system_enableula_sacl.ps1",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\WEC\\registry_terminal_server_sacl.ps1",
      "powershell Restart-Computer -Force",
    ]
     
  }
  root_block_device {
    delete_on_termination = true
  }
}


/*
Windows Workstations:
This process is going to provision from a Pre-Built AMI.
These AMI's already has been domain joined prior to this process
*/


 # ACCT001 Build
resource "aws_instance" "acct001" {
  instance_type = "t2.medium"
  ami = coalesce(data.aws_ami.acct001_ami.image_id, var.acct001_ami)

  tags = {
    Name = "ACCT001.shire.com"
  }

  subnet_id              = aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.windows.id]
  private_ip             = "172.18.39.100"


   provisioner "remote-exec" {
    connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "winrm"
      user        = "User"
      password    = "S@lv@m3!M0d3" 
      insecure    = "true"
      
    }
    inline = [
      "powershell set ExecutionPolicy Unrestricted -Force",
      "powershell git clone https://github.com/jsecurity101/mordor.git C:\\mordor",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\Workstations\\registry_system_enableula_sacl.ps1",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\Workstations\\registry_terminal_server_sacl.ps1",
      "powershell Restart-Computer -Force",
    ]
     
  }
  root_block_device {
    delete_on_termination = true
  }
}


 # HR001 Build
resource "aws_instance" "hr001" {
  instance_type = "t2.medium"
  ami = coalesce(data.aws_ami.hr001_ami.image_id, var.hr001_ami)

  tags = {
    Name = "HR001.shire.com"
  }

  subnet_id              = aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.windows.id]
  private_ip             = "172.18.39.106"


   provisioner "remote-exec" {
    connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "winrm"
      user        = "User"
      password    = "S@lv@m3!M0d3" 
      insecure    = "true"
      
    }
    inline = [
      "powershell set ExecutionPolicy Unrestricted -Force",
      "powershell git clone https://github.com/jsecurity101/mordor.git C:\\mordor",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\Workstations\\registry_system_enableula_sacl.ps1",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\Workstations\\registry_terminal_server_sacl.ps1",
      "powershell Restart-Computer -Force",
    ]
     
  }
  root_block_device {
    delete_on_termination = true
  }
}


 # IT001 Build
resource "aws_instance" "it001" {
  instance_type = "t2.medium"
  ami = coalesce(data.aws_ami.it001_ami.image_id, var.it001_ami)

  tags = {
    Name = "IT001.shire.com"
  }

  subnet_id              = aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.windows.id]
  private_ip             = "172.18.39.105"


   provisioner "remote-exec" {
    connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "winrm"
      user        = "User"
      password    = "S@lv@m3!M0d3" 
      insecure    = "true"
      
    }
    inline = [
      "powershell set ExecutionPolicy Unrestricted -Force",
      "powershell git clone https://github.com/jsecurity101/mordor.git C:\\mordor",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\Workstations\\registry_system_enableula_sacl.ps1",
      "powershell C:\\mordor\\environment\\shire\\aws\\scripts\\Workstations\\registry_terminal_server_sacl.ps1",
      "powershell Restart-Computer -Force",

    ]
     
  }
  root_block_device {
    delete_on_termination = true
  }
}

