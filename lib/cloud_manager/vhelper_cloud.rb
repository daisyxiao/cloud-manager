module VHelper::CloudManager
  class VHelperCloud
    attr_reader :vc_share_datastore_patten
    attr_reader :vc_local_datastore_patten
    attr_reader :vc_req_datacenter
    attr_reader :vc_req_clusters
    attr_reader :allow_mixed_datastores
    attr_reader :racks
    attr_reader :need_abort

    def initialize(logger)
      @logger = logger
      @dc_resource = nil
      @clusters = nil
      @vm_lock = Mutex.new
      @deploy_vms = {}
      @existed_vms = {}
      @finished_vms = {}
      @failure_vms = {}
      @preparing_vms = {}
      @need_abort = nil

      @status = CLUSTER_BIRTH
      @rs_lock = Mutex.new
      @client = nil
      @success = false
      @finished = false
    end

    def add_deploying_vm(vm)
      @vm_lock.synchronize {
        @deploy_vms[vm.name] = vm
        @preparing_vms.delete(vm.name)
      }
    end

    def add_existed_vm(vm)
      @logger.debug("Add existed vm")
      @vm_lock.synchronize {
        @existed_vms[vm.name] = vm
      }
    end

    def existed_vm_move_to_finish(vm, options={})
      @vm_lock.synchronize {
        @existed_vms.delete(vm.name)
        @finished_vms[vm.name] = vm
      }
    end

    def deploying_vm_move_to_existed(vm, options={})
      @logger.debug("deploy to existed vm")
      @vm_lock.synchronize {
        @deploy_vms.delete(vm.name)
        @existed_vms[vm.name] = vm
      }
    end

    def create_cloud_provider(cloud_provider)
      @name = cloud_provider["name"]
      #@vc_req_resource_pools = resource_pool.split(',').delete_if(&:empty?)
      @vc_req_datacenter = cloud_provider["vc_datacenter"]
      @vc_req_clusters = cloud_provider["vc_clusters"]
      @vc_address = cloud_provider["vc_addr"]
      @vc_username = cloud_provider["vc_user"]
      @vc_password = cloud_provider["vc_pwd"]
      @vc_share_datastore_patten = cloud_provider["vc_shared_datastore_pattern"]
      @vc_local_datastore_patten = cloud_provider["vc_local_datastore_pattern"]
      @client_name = cloud_provider["cloud_adapter"] || "fog"
      @allow_mixed_datastores = nil
      @racks = nil
    end

    def attach_adapter(client)
      @client = client
    end

    def inspect
      "<vHelperCloud: #{@name} vc: #{@vc_address} status: #{@status} client: #{@client.inspect}>"
    end

    def delete(cloud_provider, cluster_info, task)
      @logger.debug("enter delete cluster ... ")
      create_cloud_provider(cloud_provider)
      dc_resources, vm_groups_existed, vm_groups_input = prepare_working(cluster_info)
      dc_resources.clusters.each_value { |cluster|
        vm_map_by_threads(cluster.vms) { |vm|
          #@logger.debug("Can we delete #{vm.name} same as #{cluster_info["name"]}?")
          result = get_from_vm_name(vm.name)
          next unless result
          cluster_name = result[1]
          group_name = result[2]
          num = result[3]
          #@logger.debug("vm split to #{cluster_name}::#{group_name}::#{num}")
          if cluster_info["name"] == cluster_name
            @logger.debug("delete vm : #{vm.name}")
            @client.vm_destroy(vm)
          end
        }
      }
      cluster_done(task)
      @logger.debug("delete all vm's")
      #TODO add code here to delete all cluster
    end

    def prepare_working(cluster_info)
      ###########################################################
      # Connect to Cloud server
      @cluster_name = cluster_info["name"]
      @logger.debug("Connect to Cloud Server #{@client_name} #{@vc_address} user:#{@vc_username}/#{vc_password}...")
      @status = CLUSTER_CONNECT
      @client = ClientFactory.create(@client_name, @logger)
      @client.login(@vc_address, @vc_username, @vc_password)

      @logger.debug("Create Resources ...")
      @resources = Resources.new(@client, self)

      ###########################################################
      # Create inputed vm_group from vhelper input
      @logger.debug("Create vm group from vhelper input...")
      vm_groups_input = create_vm_group_from_vhelper_input(cluster_info, @vc_req_datacenter)

      log_obj_to_file(vm_groups_input, 'vm_groups_input')
      vm_groups_existed = {}
      dc_resources = {}
      @status = CLUSTER_FETCH_INFO
      dc_resources = @resources.fetch_datacenter(@vc_req_datacenter)

      log_obj_to_file(dc_resources, 'dc_resource-first')
      @logger.debug("Create vm group from resources...")
      vm_groups_existed = create_vm_group_from_resources(dc_resources, cluster_info["name"])
      log_obj_to_file(vm_groups_existed, 'vm_groups_existed')

      @logger.info("Finish collect vm_group info from resources")

      [dc_resources, vm_groups_existed, vm_groups_input]
    end

    def release_connection
      return if @client.nil?
      @client.logout
      @client = nil
    end

    def log_obj_to_file(obj, str)
      File.open("#{str}.yaml", 'w'){|f| YAML.dump(obj, f)} 
    end

    def create_and_update(cloud_provider, cluster_info, task)
      @logger.debug("enter create_and_update...")
      create_cloud_provider(cloud_provider)
      @vm_lock.synchronize {
        @deploy_vms = {}
        @existed_vms = {}
        @preparing_vms = {}
        @failure_vms = {}
        @finished_vms = {}
      }
      #FIXME we only support one cluster, currently

      #@logger.debug("#{cluster_info.inspect}")
      @logger.debug("Begin vHelper work...")
      cluster_changes = []

      begin
        dc_resources, vm_groups_existed, vm_groups_input = prepare_working(cluster_info)
        ###########################################################
        # Create existed vm groups
        
        unless vm_groups_existed.empty?
          ###########################################################
          #Checking and do difference
          @status = CLUSTER_UPDATE
          nodifference, cluster_changes = cluster_diff(dc_resources, vm_groups_input, vm_groups_existed)
          if nodifference
            @logger.info("No difference here")
            @status = CLUSTER_DONE
          else
            log_obj_to_file(cluster_changes, 'cluster_changes')
          end
        end
      rescue => e
        @logger.debug("Prepare working failed.")
        @logger.debug("#{e} - #{e.backtrace.join("\n")}")
        cluster_failed(task)
        #TODO add all kinds of error handlers here
        raise e
      end
      if @status == CLUSTER_DONE
        cluster_done(task)
        @logger.info("No work need to do!")
        return
      end

      retry_num = 1

      retry_num.times do |cycle_num|
        begin
          ###########################################################
          #Caculate cluster placement
          @logger.debug("Begin placement")
          @status = CLUSTER_PLACE
          placement = cluster_placement(dc_resources, vm_groups_input, vm_groups_existed, cluster_info)
          log_obj_to_file(placement, 'placement')

          @logger.debug("Begin deploy")
          @status = CLUSTER_DEPLOY
          successful = cluster_deploy(cluster_changes , placement)
          break if successful

          @status = CLUSTER_FETCH_INFO
          dc_resources = @resources.fetch_datacenter
          #TODO add all kinds of error handlers here
          @logger.info("reload datacenter resources from cloud")

          log_obj_to_file(dc_resources, "dc_resource-#{cycle_num}")
        rescue => e
          @logger.debug("#{e} - #{e.backtrace.join("\n")}")
          if cycle_num + 1  >= retry_num
            cluster_failed(task)
            raise
          end
          @logger.debug("Loop placement faild and retry #{cycle_num} loop")
        end
      end
      ###########################################################
      # Cluster deploy successfully
      @status = CLUSTER_DONE
      cluster_done(task)
    end

    def get_result_by_vms(servers, vms, options={})
      vms.each_value { |vm|
        result = get_from_vm_name(vm.name)
        return if result.nil?
        vm.cluster_name = result[1]
        vm.group_name = result[2]
        vm.created = options[:created]
        servers << vm
      }
    end

    def get_result
      result = IaasResult.new
      @vm_lock.synchronize {
        result.waiting = @preparing_vms.size
        result.deploy = @deploy_vms.size
        result.waiting_start = @existed_vms.size
        result.success = @finished_vms.size
        result.failure = @failure_vms.size
        result.succeed = @success && result.failure <= 0
        result.running = result.deploy + result.waiting + result.waiting_start
        result.total = result.running + result.success + result.failure
        get_result_by_vms(result.servers, @deploy_vms, :created => false) 
        get_result_by_vms(result.servers, @existed_vms, :created => true)
        get_result_by_vms(result.servers, @failure_vms, :created => false)
        get_result_by_vms(result.servers, @finished_vms, :created => true)
      }
      result
    end

    def get_progress
      progress = IaasProcess.new
      progress.cluster_name = @cluster_name
      progress.result = get_result
      progress.status = @status
      progress.finished = @finished
      progress.progress = 0
      progress.progress = ((progress.result.success+progress.result.failure) *100/progress.result.total) if progress.result.total> 0
      progress
    end

    def list_vms(cloud_provider, cluster_info, task)
      @logger.debug("enter list_vms...")
      create_cloud_provider(cloud_provider)
      dc_resources, vm_groups_existed, vm_groups_input = prepare_working(cluster_info)
      get_result.servers
    end

    def cluster_failed(task)
      @logger.debug("Enter Cluster_failed")
      task.set_finish("failed")
      @success = false
      @finished = true
    end

    def cluster_done(task)
      @logger.debug("Enter cluster_done")
      # TODO finish cluster information
      task.set_finish("success")
      @success = true
      @finished = true
    end

  end
end
