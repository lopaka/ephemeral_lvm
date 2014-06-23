#
# Cookbook Name:: ephemeral_lvm
# Recipe:: default
#
# Copyright (C) 2013 RightScale, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Include the lvm::default recipe which sets up the resources/providers for lvm
#
include_recipe "lvm"

if !node.attribute?('cloud') || !node['cloud'].attribute?('provider') || !node.attribute?(node['cloud']['provider'])
  log "Not running on a known cloud, not setting up ephemeral LVM"
else
  # Obtain the current cloud
  cloud = node['cloud']['provider']

  # Obtain the available ephemeral devices. See "libraries/helper.rb" for the definition of
  # "get_ephemeral_devices" method.
  #
  ephemeral_devices = EphemeralLvm::Helper.get_ephemeral_devices(cloud, node)

  if ephemeral_devices.empty?
    log "No ephemeral disks found. Skipping setup."
  else
    log "Ephemeral disks found for cloud '#{cloud}': #{ephemeral_devices.inspect}"

    # Create the volume group and logical volume. If more than one ephemeral disk is found,
    # they are created with LVM stripes with the stripe size set in the attributes.
    #
    lvm_volume_group node['ephemeral_lvm']['volume_group_name'] do
      physical_volumes ephemeral_devices
    end

    lvm_logical_volume node['ephemeral_lvm']['logical_volume_name'] do
      group node['ephemeral_lvm']['volume_group_name']
      size node['ephemeral_lvm']['logical_volume_size']
      if ephemeral_devices.size > 1
        stripes ephemeral_devices.size
        stripe_size node['ephemeral_lvm']['stripe_size'].to_i
      end
    end

    logical_volume_device_name = node['ephemeral_lvm']['volume_group_name'].gsub(/-/,'--') + "-" + node['ephemeral_lvm']['logical_volume_name'].gsub(/-/,'--')

    # Encrypt if enabled
    if node['ephemeral_lvm']['encryption'] == true || node['ephemeral_lvm']['encryption'] == 'true'

      require 'securerandom'

      # Verify cryptsetup is installed
      package 'cryptsetup'

      # Passing 128 to hex returns string of 128*2=256
      encryption_key = SecureRandom.hex(128)

      execute 'cryptsetup format ephemeral_lvm' do
        environment 'ENCRYPTION_KEY' => encryption_key
        command "echo -n ${ENCRYPTION_KEY} | cryptsetup luksFormat /dev/mapper/#{logical_volume_device_name} --batch-mode"
        not_if "cryptsetup isLuks /dev/mapper/#{logical_volume_device_name}"
      end

      execute 'cryptsetup open ephemeral_lvm' do
        environment 'ENCRYPTION_KEY' => encryption_key
        command "echo -n ${ENCRYPTION_KEY} | cryptsetup luksOpen /dev/mapper/#{logical_volume_device_name} encrypted-#{logical_volume_device_name} --key-file=-"
        not_if { ::File.exists?("/dev/mapper/encrypted-#{logical_volume_device_name}") }
      end
    end

    # Format, add fstab entry, and mount
    filesystem logical_volume_device_name do
      fstype node['ephemeral_lvm']['filesystem']
      device(
        if node['ephemeral_lvm']['encryption'] == true || node['ephemeral_lvm']['encryption'] == 'true'
          "/dev/mapper/encrypted-#{logical_volume_device_name}"
        else
          "/dev/mapper/#{logical_volume_device_name}"
        end
      )
      mount node['ephemeral_lvm']['mount_point']
      pass 0
      options "defaults,noatime"
      action [:create, :enable, :mount]
    end
  end
end
