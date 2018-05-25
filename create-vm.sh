#!/bin/bash

set -e

ipAddress=192.168.0.150
netmaskSize=24
gateway=192.168.0.1
dns1=1.1.1.1
dns2=1.0.0.1
hostname=xenial
defaultPassword=passw0rd
memoryUnits=GiB
memory=2
vcpus=2
bridge=br0
rootImgSize=8G
networkDevice="enp0s2"
extraVolumeSize=

usage() {
cat <<END
Usage: $0 [options] [hostname]

where hostname will be both the VM's configured hostname 
and the name of the libvirt domain. The default is ${hostname}.

OPTIONS
    --ip-address ${ipAddress}
    --netmask-size ${netmaskSize}
    --gateway ${gateway}
    --network-dev ${networkDevice}
    --password ${defaultPassword}
    --memory ${memory}
    --memory-units ${memoryUnits}
    --vcpus ${vcpus}
    --bridge ${bridge}
    --root-size ${rootImgSize}
    --extra-volume ${extraVolumeSize}
       If you want an extra volume attached to the image, declare its
       size in units accpepted by qemu-img, such as 20G
    
END
}

while [[ $# -ge 1 ]]; do
  arg=$1
  shift
  case ${arg} in
    -h|--help)
      usage
      exit 0
      ;;
    --ip-address)
      ipAddress=$1
      shift
      ;;
    --netmask-size)
      netmaskSize=$1
      shift
      ;;
    --gateway)
      gateway=$1
      shift
      ;;
    --network-dev)
      networkDevice=$1
      shift
      ;;
    --password)
      defaultPassword=$1
      shift
      ;;
    --memory)
      memory=$1
      shift
      ;;
    --memory-units)
      memoryUnits=$1
      shift
      ;;
    --vcpus)
      vcpus=$1
      shift
      ;;
    --bridge)
      bridge=$1
      shift
      ;;
    --root-size)
      rootImgSize=$1
      shift
      ;;
    --extra-volume)
      extraVolumeSize=$1
      shift
      ;;
    --*|-*)
      echo "Unknown argument: ${arg}"
      exit 1
      ;;
    *)
      hostname=${arg}
      ;;
  esac
done

if [ $UID != 0 ]; then
  echo "This must be run as root"
  exit 1
fi

imagesDir=/var/lib/libvirt/images
netconfig=/tmp/network-config-$$.yml
userdata=/tmp/user-data-$$.yml
domainXml=/tmp/domain-$$.yml
baseImgUrl=https://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img
baseImgName=xenial-server-cloudimg-amd64-disk1.img
extraDevices=

writeNetworkConfig() {
  cat > ${netconfig} <<END
version: 1
config:
  - type: nameserver
    address:
      - ${dns1}
      - ${dns2}
  - type: physical
    name: ${networkDevice}
    subnets:
     - control: auto
       type: static
       address: ${ipAddress}/${netmaskSize}
       gateway: ${gateway}
END
}

writeUserData() {
  authorizedKey=$(ssh-keygen -y -f $HOME/.ssh/id_rsa)

  cat > ${userdata} <<END
#cloud-config

hostname: ${hostname}
manage_etc_hosts: localhost
password: ${defaultPassword}
chpasswd:
  expire: false
ssh_pwauth: no
ssh_authorized_keys:
  - ${authorizedKey}
packages:
  - python
END
}

writeDomainXml() {
  cat > ${domainXml} <<END
<domain type='kvm'>
    <name>${hostname}</name>
    <memory unit='${memoryUnits}'>${memory}</memory>
    <os>
        <type>hvm</type>
        <boot dev="hd"/>
    </os>
    <vcpu>${vcpus}</vcpu>
    <devices>
        <interface type='bridge'>
            <source bridge='${bridge}'/>
            <model type='virtio'/>
        </interface>
        <disk type='file' device='disk'>
            <driver type='qcow2' cache='none'/>
            <source file='${rootImgPath}'/>
            <target dev='vda' bus='virtio'/>
        </disk>
        <disk type='file' device='disk'>
            <source file='${userdataImgPath}'/>
            <target dev='vdb' bus='virtio'/>
        </disk>
        <serial type="pty">
           <source path='/dev/pts/1'/>
           <target port="0"/>
        </serial>
        <console type="pty">
           <source path='/dev/pts/1'/>
           <target type="serial" port="0"/>
        </console>
        ${extraDevices}
    </devices>
</domain>
END
}

createImages() {
  echo "Preparing images..."
  baseImgPath=${imagesDir}/${baseImgName}
  [ -f ${baseImgPath} ] || curl -o ${baseImgPath} ${baseImgUrl}

  declare -g rootImgPath=${imagesDir}/${hostname}-root.img
  qemu-img create -b ${baseImgPath} -f qcow2 ${rootImgPath} ${rootImgSize}

  declare -g userdataImgPath=${imagesDir}/${hostname}-user-data.img
  cloud-localds -N ${netconfig} ${userdataImgPath} ${userdata}
}

addExtraVolume() {
  extraImgPath=${imagesDir}/${hostname}-extra.img
  qemu-img create -f qcow2 ${extraImgPath} ${extraVolumeSize}

  extraDevices="$extraDevices
	<disk type='file' device='disk'>
            <driver name='qemu' type='qcow2' cache='none'/>
	    <source file='${extraImgPath}'/>
	    <target dev='vdc' bus='virtio'/>
	</disk>
"
}

echo "Creating VM ${hostname}..."

trap "rm -f ${netconfig} ${userdata} ${domainXml}" EXIT
writeNetworkConfig
writeUserData
createImages
if [[ $extraVolumeSize ]]; then
  addExtraVolume
fi
writeDomainXml

virsh define ${domainXml}
virsh start ${hostname}
virsh autostart ${hostname}

echo "
You can now console into the VM using:

  virsh console ${hostname}
"
