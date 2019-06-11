# This concern has the methods to be called inside azure_rm.rb
module ForemanAzureRM
  module VMExtensions
    module ManagedVM
      extend ActiveSupport::Concern

      def define_managed_storage_profile(vm_name, vhd_path, publisher, offer, sku, version,
                                           os_disk_caching, platform, premium_os_disk)
        storage_profile = ComputeModels::StorageProfile.new
        os_disk = ComputeModels::OSDisk.new
        managed_disk_params = ComputeModels::ManagedDiskParameters.new

        # Create OS disk
        os_disk.name = "#{vm_name}-osdisk"
        os_disk.os_type = platform
        os_disk.create_option = ComputeModels::DiskCreateOptionTypes::FromImage
        os_disk.caching = if os_disk_caching.present?
                            case os_disk_caching
                              when 'None'
                                ComputeModels::CachingTypes::None
                              when 'ReadOnly'
                                ComputeModels::CachingTypes::ReadOnly
                              when 'ReadWrite'
                                ComputeModels::CachingTypes::ReadWrite
                              else
                                # ARM best practices stipulate RW caching on the OS disk
                                ComputeModels::CachingTypes::ReadWrite
                            end
                          end
        managed_disk_params.storage_account_type = if premium_os_disk == 'true'
                                                     ComputeModels::StorageAccountTypes::PremiumLRS
                                                   else
                                                     ComputeModels::StorageAccountTypes::StandardLRS
                                                   end
        os_disk.managed_disk = managed_disk_params
        storage_profile.os_disk = os_disk

        # Currently eliminating data disk creation since capability does not exist.

        if vhd_path.nil?
          # We are using a marketplace image
          storage_profile.image_reference = image_reference(publisher, offer,
                                                            sku, version)
        else
          # We are using a custom managed image
          image_ref = ComputeModels::ImageReference.new
          image_ref.id = vhd_path
          storage_profile.image_reference = image_ref
        end
        storage_profile
      end

      def image_reference(publisher, offer, sku, version)
        image_reference = ComputeModels::ImageReference.new
        image_reference.publisher = publisher
        image_reference.offer = offer
        image_reference.sku = sku
        image_reference.version = version
        image_reference
      end

      def define_network_profile(network_interface_card_ids)
        network_interface_cards = []
        network_interface_card_ids.each_with_index do |id, index|
          nic = ComputeModels::NetworkInterfaceReference.new
          nic.id = id
          nic.primary = true
          network_interface_cards << nic
        end
        network_profile = ComputeModels::NetworkProfile.new
        network_profile.network_interfaces = network_interface_cards
        network_profile
      end

      def create_nics(args = {})
        nics               = []
        formatted_region = args[:azure_vm][:location].gsub(/\s+/, '').downcase
        args[:interfaces_attributes].each do |nic, attrs|
          attrs[:pubip_alloc]  = attrs[:bridge]
          attrs[:privip_alloc] = (attrs[:name] == 'false') ? false : true
          pip_alloc            = case attrs[:pubip_alloc]
                                   when 'Static'
                                     NetworkModels::IPAllocationMethod::Static
                                   when 'Dynamic'
                                     NetworkModels::IPAllocationMethod::Dynamic
                                   when 'None'
                                     nil
                                 end
          priv_ip_alloc        = if attrs[:priv_ip_alloc]
                                   NetworkModels::IPAllocationMethod::Static
                                 else
                                   NetworkModels::IPAllocationMethod::Dynamic
                                 end
          if pip_alloc.present?
            public_ip_params = NetworkModels::PublicIPAddress.new.tap do |ip|
              ip.location = formatted_region
              ip.public_ipallocation_method = pip_alloc
            end
            pip = sdk.create_or_update_pip(args[:azure_vm][:resource_group],
                                           "#{args[:azure_vm][:vm_name]}-pip#{nic}",
                                           public_ip_params)
          end
          new_nic = sdk.create_or_update_nic(
            args[:azure_vm][:resource_group],
            "#{args[:azure_vm][:vm_name]}-nic#{nic}",
            NetworkModels::NetworkInterface.new.tap do |interface|
              interface.location = formatted_region
              interface.ip_configurations = [
                NetworkModels::NetworkInterfaceIPConfiguration.new.tap do |nic_conf|
                  nic_conf.name = "#{args[:azure_vm][:vm_name]}-nic#{nic}"
                  nic_conf.private_ipallocation_method = priv_ip_alloc
                  nic_conf.subnet = subnets(args[:azure_vm][:location]).select{ |subnet| subnet.id == attrs[:network] }.first
                  nic_conf.public_ipaddress = pip.present? ? pip : nil
                end
              ]
            end
          )
          nics << new_nic
        end
        nics
      end

      def create_managed_virtual_machine(vm_hash)
        custom_data = vm_hash[:custom_data]
        msg = "Creating Virtual Machine #{vm_hash[:name]} in Resource Group #{vm_hash[:resource_group]}."
        logger.debug msg
        vm_create_params = ComputeModels::VirtualMachine.new.tap do |vm|
          vm.location = vm_hash[:location]
          unless vm_hash[:availability_set_id].nil?
            sub_resource = MsRestAzure::SubResource.new
            sub_resource.id = vm_hash[:availability_set_id]
            vm.availability_set = sub_resource
          end
          # If image UUID begins with / it is a custom managed image
          # Otherwise it is a marketplace URN
          unless vm_hash[:vhd_path].start_with?('/')
            urn = vm_hash[:vhd_path].split(':')
            vm_hash[:publisher] = urn[0]
            vm_hash[:offer]     = urn[1]
            vm_hash[:sku]       = urn[2]
            vm_hash[:version]   = urn[3]
            vm_hash[:vhd_path] = nil
          end

          vm.os_profile = ComputeModels::OSProfile.new.tap do |os_profile|
            os_profile.computer_name  = vm_hash[:name]
            os_profile.admin_username = vm_hash[:username]
            os_profile.admin_password = vm_hash[:password]

            # Adding the ssh-key support for authentication
            os_profile.linux_configuration = ComputeModels::LinuxConfiguration.new.tap do |linux|
              linux.disable_password_authentication = vm_hash[:disable_password_authentication]
              linux.ssh = ComputeModels::SshConfiguration.new.tap do |ssh_config|
                ssh_config.public_keys = [
                  ComputeModels::SshPublicKey.new.tap do |foreman_key|
                    foreman_key.key_data = key_pair.public
                    foreman_key.path = "/home/#{vm_hash[:username]}/.ssh/authorized_keys"
                  end
                ]
                if vm_hash[:ssh_key_data].present?
                  key_data = vm_hash[:ssh_key_data]
                  pub_key = ComputeModels::SshPublicKey.new
                  pub_key.key_data = key_data
                  pub_key.path = "/home/#{vm_hash[:username]}/.ssh/authorized_keys"
                  ssh_config.public_keys << pub_key
                end
              end
            end
            # added custom_data here so that azure's vm gets this
            os_profile.custom_data    = Base64.strict_encode64(custom_data) unless vm_hash[:custom_data].nil?
          end
          vm.storage_profile = define_managed_storage_profile(
                                                                vm_hash[:name],
                                                                vm_hash[:vhd_path],
                                                                vm_hash[:publisher],
                                                                vm_hash[:offer],
                                                                vm_hash[:sku],
                                                                vm_hash[:version],
                                                                vm_hash[:os_disk_caching],
                                                                vm_hash[:platform],
                                                                vm_hash[:premium_os_disk],
                                                              )
          vm.hardware_profile = ComputeModels::HardwareProfile.new.tap do |hw_profile|
            hw_profile.vm_size = vm_hash[:vm_size]
          end
          vm.network_profile = define_network_profile(vm_hash[:network_interface_card_ids])
        end

        response = sdk.create_or_update_vm(vm_hash[:resource_group], vm_hash[:name], vm_create_params)
        logger.debug "Virtual Machine #{vm_hash[:name]} Created Successfully."
        response
      end

      def create_vm_extension(args = {})
        if args[:azure_vm][:script_command].present? || args[:azure_vm][:script_uris].present?
          extension = ComputeModels::VirtualMachineExtension.new
          if args[:azure_vm][:platform] == 'Linux'
            extension.publisher = 'Microsoft.Azure.Extensions'
            extension.virtual_machine_extension_type = 'CustomScript'
            extension.type_handler_version = '2.0'
          end
          extension.auto_upgrade_minor_version = true
          extension.location = args[:azure_vm][:location].gsub(/\s+/, '').downcase
          extension.settings = {
                'commandToExecute' => args[:azure_vm][:script_command],
                'fileUris'         => args[:azure_vm][:script_uris].split(',')
          }
          sdk.create_or_update_vm_extensions(args[:azure_vm][:resource_group],
                                             args[:azure_vm][:vm_name],
                                             'ForemanCustomScript',
                                             extension)
        end
      end
    end
  end
end