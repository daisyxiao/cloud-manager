###############################################################################
#    Copyright (c) 2012 VMware, Inc. All Rights Reserved.
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
################################################################################

# @since serengeti 0.5.0
# @version 0.5.0

module Serengeti
  module CloudManager

    class Cloud
      attr_accessor :name
      attr_accessor :vc_req_resource_pools
      attr_accessor :vc_address
      attr_accessor :vc_username
      attr_accessor :vc_password

      attr_accessor :status
      attr_accessor :clusters
      attr_accessor :vm_groups
      attr_accessor :vms
      attr_reader :input_cluster_info
      attr_reader :action

      attr_accessor :placement_failed
      attr_accessor :cloud_error_msg_que

      attr_reader :vc_share_datastore_pattern
      attr_reader :vc_local_datastore_pattern
      attr_reader :vc_req_datacenter
      attr_reader :vc_req_rps

      attr_reader :racks
      attr_reader :need_abort

      CLOUD_DEBUG_ON = false

      def initialize(cluster_info)
        @logger = Serengeti::CloudManager::Cloud.Logger
        @dc_resource = nil
        @clusters = nil
        @vm_lock = Mutex.new
        @deploy_vms = {}
        @existed_vms = {}
        @finished_vms = {}
        @failed_vms = {}
        @placed_vms = {}
        @need_abort = nil
        @cluster_name = cluster_info["name"]

        @status = CLUSTER_BIRTH
        @rs_lock = Mutex.new
        @client = nil
        @success = false
        @finished = false
        @placement_failed = 0
        @cluster_failed_num = 0
        @cloud_error_msg_que = []
      end

      def add_2existed_vm(vm)
        @logger.debug("Add existed vm")
        @vm_lock.synchronize { @existed_vms[vm.name] = vm }
      end

      def set_cluster_error_msg(msg)
        @cloud_error_msg_que << msg
      end
      def mov_vm(vm, src_vms, des_vms)
        @vm_lock.synchronize do
          return if !src_vms.has_key?(vm.name)
          # vm in this vms, move to des vms
          src_vms.delete(vm.name)
          des_vms[vm.name] = vm
        end
      end

      def req_clusters_rp_to_hash(a)
        rps = {}
        # resource_pool's name can be the same between different clusters
        a.map { |v| rps[v['name']] = v["vc_rps"] }
        rps
      end

      def create_cloud_provider(cloud_provider)
        @cloud_provider = cloud_provider
        @name = cloud_provider["name"]
        raise "cloud provider name is nil!" if @name.nil?
        @vc_req_datacenter = cloud_provider["vc_datacenter"]
        raise "datacenter's name is nil!" if @vc_req_datacenter.nil?

        raise "vc_clusters is nil" if cloud_provider["vc_clusters"].nil?
        @vc_req_rps = req_clusters_rp_to_hash(cloud_provider["vc_clusters"])
        @logger.debug("req_rps:#{@vc_req_rps.pretty_inspect}")

        @logger.debug("Show clusters_req:#{@vc_req_rps}")

        @vc_address = cloud_provider["vc_addr"]
        raise "cloud_provider's IP address is nil." if @vc_address.nil?

        @vc_username = cloud_provider["vc_user"]
        @vc_password = cloud_provider["vc_pwd"]
        @vc_share_datastore_pattern = change_wildcard2regex(cloud_provider["vc_shared_datastore_pattern"]||[])
        @vc_local_datastore_pattern = change_wildcard2regex(cloud_provider["vc_local_datastore_pattern"]||[])
        @client_name = cloud_provider["cloud_adapter"] || "fog"
        @racks = nil
      end

      def template_placement?
        @cloud_provider['template_placement'] || false;
      end

      def attach_adapter(client)
        @client = client
      end

      def inspect
        "<Cloud: #{@name} vc: #{@vc_address} status: #{@status} client: #{@client.inspect}>"
      end

      # Setting existed vm parameter from input
      def setting_existed_group_by_input(vm_groups_existed, vm_groups_input)
        #@logger.debug("#{vm_groups_existed.class}")
        vm_groups_existed.each_value do |exist_group|
          #@logger.debug("exist group: #{exist_group.pretty_inspect}")
          input_group = vm_groups_input[exist_group.name]
          next if input_group.nil?
          @logger.debug("find same group #{exist_group.name}, and change each vm's configuration")
          exist_group.vm_ids.each_value { |vm| vm.ha_enable = input_group.req_info.ha }
        end
      end

      def update_input_group_by_existed(vm_groups_input, vm_groups_existed, cluster_data)
        # remove ips associated with existing vms from input ip pool
        vm_groups_existed.each_value do |exist_group|
          input_group = vm_groups_input[exist_group.name]
          next if input_group.nil?
          if cluster_data && cluster_data['group']
            cluster_data_instances = cluster_data['group'].select \
              { |group| group[instances] if group['name'] == exist_group.name}.first
            cluster_data_instances.each { |vm| input_group.network_res.ip_remove(0, vm['ip_address']) }
          end
          @logger.debug("find same group #{exist_group.name}, and remove existed vm ip from input pool")
          exist_group.vm_ids.each_value { |vm| input_group.network_res.ip_remove(0, vm.ip_address) }
        end
      end

      def client_op(cloud, working)
        begin
          return yield
        rescue => e
          @logger.error("#{working} failed.\n #{e} - #{e.backtrace.join("\n")}")
          set_cluster_error_msg("#{working} failed. Reason: #{e}")
          @cluster_failed_num += 1
          raise e
        end
      end

      def prepare_working(cluster_info, cluster_data)
        ###########################################################
        # Connect to Cloud server
        #@cluster_name = cluster_info["name"]
        @logger.debug("Connect to Cloud Server #{@client_name} #{@vc_address} user:#{@vc_username}/#{vc_password}...")
        @input_cluster_info = cluster_info
        @status = CLUSTER_CONNECT
        @client = ClientFactory.create(@client_name)
        #client connect need more connect sessions
        client_op(self, 'vSphere login') { @client.login(@vc_address, @vc_username, @vc_password) }

        @logger.debug("Create Resources ...")
        @resources = Resources.new(@client, self)

        ###########################################################
        # Create inputed vm_group from serengeti input
        @logger.debug("Create vm group from input...")
        vm_groups_input = create_vm_group_from_serengeti_input(cluster_info, @vc_req_datacenter)

        log_obj_to_file(vm_groups_input, 'vm_groups_input')
        vm_groups_existed = {}
        dc_resources = {}
        @status = CLUSTER_FETCH_INFO
        dc_resources = client_op(self, 'Fetch vSphere info') { \
          @resources.fetch_datacenter(@vc_req_datacenter, cluster_info['template_id']) }
        @vm_sys_disk_size  = nil
        dc_resources.vm_template.disks.each_value { |disk| break @vm_sys_disk_size = disk.size if disk.unit_number == 0 }
        @logger.debug("template vm disk size: #{@vm_sys_disk_size}")

        log_obj_to_file(dc_resources, 'dc_resource-first')
        @logger.debug("Create vm group from resources...")
        vm_groups_existed = create_vm_group_from_resources(dc_resources, cluster_info["name"])
        log_obj_to_file(vm_groups_existed, 'vm_groups_existed')

        setting_existed_group_by_input(vm_groups_existed, vm_groups_input)

        update_input_group_by_existed(vm_groups_input, vm_groups_existed, cluster_data)

        @logger.info("Finish collect vm_group info from resources")
        [dc_resources, vm_groups_existed, vm_groups_input]
      end

      def release_connection
        if !cloud_error_msg_que.empty?
          @logger.debug("cloud manager have error/warning message. please chcek it, it is helpful for debugging")
          @logger.debug("#{cloud_error_msg_que.pretty_inspect}")
        end
        return if @client.nil?
        @client.logout
        @client = nil
      end

      def log_obj_to_file(obj, str)
        return if !CLOUD_DEBUG_ON
        File.open("#{str}.yaml", 'w'){ |f| YAML.dump(obj, f) }
      end

      def action_process(act, task)
        result = nil
        begin
          @logger.info("begin action:#{act}")
          @action = act
          result = yield
          @logger.info("finished action:#{act}")
        rescue => e
          @logger.error("#{act} failed with #{e}")
          set_cluster_error_msg("#{act} failed with #{e}")
          cluster_failed(task)
          return 'failed'
        end
        result
      end

      def change_wildcard2regex_str(str)
        str.gsub(/[*]/, '.*').gsub(/[?]/, '.{1}').tap { |out| return "^#{out}$" } unless str.nil?
        "^$"
      end

      def change_wildcard2regex(strArray)
        strArray.collect { |str| change_wildcard2regex_str(str) }
      end

    end
  end
end
