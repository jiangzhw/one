#!/usr/bin/env ruby
# -------------------------------------------------------------------------- #
# Copyright 2002-2013, OpenNebula Project (OpenNebula.org), C12G Labs        #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
# -------------------------------------------------------------------------- #

ONE_LOCATION = ENV["ONE_LOCATION"] if !defined?(ONE_LOCATION)

if !ONE_LOCATION
    RUBY_LIB_LOCATION = "/usr/lib/one/ruby" if !defined?(RUBY_LIB_LOCATION)
    ETC_LOCATION      = "/etc/one/" if !defined?(ETC_LOCATION)
else
    RUBY_LIB_LOCATION = ONE_LOCATION + "/lib/ruby" if !defined?(RUBY_LIB_LOCATION)
    ETC_LOCATION      = ONE_LOCATION + "/etc/" if !defined?(ETC_LOCATION)
end

EC2_DRIVER_CONF = "#{ETC_LOCATION}/ec2_driver.conf"
EC2_DRIVER_DEFAULT = "#{ETC_LOCATION}/ec2_driver.default"

# Load EC2 credentials and environment
require 'yaml'
require 'rubygems'
require 'aws-sdk'

$: << RUBY_LIB_LOCATION

require 'CommandManager'
require 'scripts_common'
require 'rexml/document'
require 'VirtualMachineDriver'

# The main class for the EC2 driver
class EC2Driver
    ACTION          = VirtualMachineDriver::ACTION
    POLL_ATTRIBUTE  = VirtualMachineDriver::POLL_ATTRIBUTE
    VM_STATE        = VirtualMachineDriver::VM_STATE

    # EC2 commands constants
    EC2 = {
        :run => {
            :cmd => :create,
            :args => {
                "AKI" => {
                    :opt => 'kernel_id'
                },
                "AMI" => {
                    :opt => 'image_id'
                },
                #"BLOCKDEVICEMAPPING" => {
                #    :opt => '-b'
                #},
                "CLIENTTOKEN" => {
                    :opt => 'client_token'
                },
                "INSTANCETYPE" => {
                    :opt => 'instance_type'
                },
                "KEYPAIR" => {
                    :opt => 'key_name'
                },
                "LICENSEPOOL" => {
                    :opt => 'license/pool'
                },
                "PLACEMENTGROUP" => {
                    :opt => 'placement/group_name'
                },
                "PRIVATEIP" => {
                    :opt => 'private_ip_address'
                },
                "RAMDISK" => {
                    :opt => 'ramdisk_id'
                },
                "SUBNETID" => {
                    :opt => 'subnet_id'
                },
                "TENANCY" => {
                    :opt => 'placement/tenancy'
                },
                "USERDATA" => {
                    :opt => 'user_data'
                },
                #"USERDATAFILE" => {
                #    :opt => '-f'
                #},
                "SECURITYGROUPS" => {
                    :opt => 'security_groups',
                    :proc => lambda {|str| str.split(',')}
                },
                "AVAILABILITYZONE" => {
                    :opt => 'placement/availability-zone'
                },
                "EBS_OPTIMIZED" => {
                    :opt => 'ebs_optimized'
                }
            }
        },
        :terminate => {
            :cmd => :terminate
        },
        :describe => {
            :cmd => :describe_instances
        },
        :associate => {
            :cmd => :associate_address,
            :args => {
                #"SUBNETID"  => {
                #    :opt  => '-a',
                #    :proc => lambda {|str| ''}
                #},
                "ELASTICIP" => {
                    :opt => 'public_ip'
                }
            }
        },
        :authorize => {
            :cmd => :authorize,
            :args => {
                "AUTHORIZEDPORTS" => {
                    :opt => '-p',
                    :proc => lambda {|str| str.split(',').join(' -p ')}
                }
            }
        },
        :reboot => {
            :cmd => :reboot
        },
        :stop => {
            :cmd => :stop
        },
        :start => {
            :cmd => :start
        },
        :tags => {
            :cmd => :create_tags,
            :args => {
                "TAGS" => {
                    :opt  => '-t',
                    :proc => lambda {|str|
                        hash = {}
                        str.split(',').each {|s|
                            k,v = s.split('=')
                            hash[k] = v
                        }
                        hash
                    }
                }
            }
        }
    }

    # EC2 constructor, loads credentials and endpoint
    def initialize(host)
        @host = host

        hybrid_ec2_conf  = YAML::load(File.read(EC2_DRIVER_CONF))

        @instance_types = hybrid_ec2_conf['instance_types']

        regions = hybrid_ec2_conf['regions']
        @region = regions[host] || regions["default"]

        AWS.config(
            'access_key_id'     => @region['access_key_id'],
            'secret_access_key' => @region['secret_access_key'],
            'region'            => @region['region_name'])

        @ec2 = AWS.ec2
    end

    # DEPLOY action, also sets ports and ip if needed
    def deploy(id, host, xml_text)
        ec2_info = get_deployment_info(host, xml_text)

        load_default_template_values

        if !ec2_value(ec2_info, 'AMI')
            STDERR.puts("Cannot find AMI in deployment file")
            exit(-1)
        end

        opts = generate_options(:run, ec2_info, {
                :min_count => 1,
                :max_count => 1})

        begin
            instance = AWS.ec2.instances.create(opts)
        rescue => e
            STDERR.puts(e.message)
            exit(-1)
        end

        tags = generate_options(:tags, ec2_info) || {}
        tags['ONE_ID'] = id
        tags.each{ |key,value|
            begin
                instance.add_tag(key, :value => value)
            rescue => e
                STDERR.puts(e.message)
                exit(-1)
            end
        }

        if ec2_value(ec2_info, 'ELASTICIP')
            begin
                instance.associate_elastic_ip(ec2_value(ec2_info, 'ELASTICIP'))
            rescue => e
                STDERR.puts(e.message)
                exit(-1)
            end
        end

        puts(instance.id)
    end

    # Shutdown a EC2 instance
    def shutdown(deploy_id)
        ec2_action(deploy_id, :terminate)
    end

    # Reboot a EC2 instance
    def reboot(deploy_id)
        ec2_action(deploy_id, :reboot)
    end

    # Cancel a EC2 instance
    def cancel(deploy_id)
        ec2_action(deploy_id, :terminate)
    end

    # Stop a EC2 instance
    def save(deploy_id)
        ec2_action(deploy_id, :stop)
    end

    # Cancel a EC2 instance
    def restore(deploy_id)
        ec2_action(deploy_id, :start)
    end

    # Get info (IP, and state) for a EC2 instance
    def poll(id, deploy_id)
        i = get_instance(deploy_id)
        puts parse_poll(i)
    end

    # Get the info of all the EC2 instances. An EC2 instance must include
    #   the ONE_ID tag, otherwise it will be ignored
    def monitor_all_vms
        totalmemory = 0
        totalcpu = 0
        @region['capacity'].each { |name, size|
            totalmemory += @instance_types[name]['memory'] * size * 1024 * 1024
            totalcpu += @instance_types[name]['cpu'] * size * 100
        }

        host_info =  "HYPERVISOR=ec2\n"
        host_info << "TOTALMEMORY=#{totalmemory}\n"
        host_info << "TOTALCPU=#{totalcpu}\n"
        host_info << "CPUSPEED=1000\n"
        host_info << "HOSTNAME=\"#{@host}\"\n"

        vms_info = "VM_POLL=YES\n"

        usedcpu = 0
        usedmemory = 0
        begin
            AWS.ec2.instances.each do |i|
                poll_data=parse_poll(i)

                one_id = i.tags['ONE_ID']

                vms_info << "VM=[\n"
                vms_info << "  ID=#{one_id || -1},\n"
                vms_info << "  DEPLOY_ID=#{i.instance_id},\n"
                vms_info << "  POLL=\"#{poll_data}\" ]\n"

                if one_id
                    name = i.instance_type
                    usedcpu += @instance_types[name]['cpu'] * 100
                    usedmemory += @instance_types[name]['memory'] * 1024 * 1024
                end

            end
        rescue => e
            STDERR.puts(e.message)
            exit(-1)
        end

        host_info << "USEDMEMORY=#{usedmemory.round}\n"
        host_info << "USEDCPU=#{usedcpu.round}\n"
        host_info << "FREEMEMORY=#{(totalmemory - usedmemory).round}\n"
        host_info << "FREECPU=#{(totalcpu - usedcpu).round}\n"

        puts host_info
        puts vms_info
    end

private

    # Get the EC2 section of the template. If more than one EC2 section
    # the CLOUD element is used and matched with the host
    def get_deployment_info(host, xml_text)
        xml = REXML::Document.new xml_text

        ec2 = nil
        ec2_deprecated = nil

        all_ec2_elements = xml.root.get_elements("//USER_TEMPLATE/EC2")

        # First, let's see if we have an EC2 site that matches
        # our desired host name
        all_ec2_elements.each { |element|
            cloud=element.elements["HOST"]
            if cloud and cloud.text.upcase == host.upcase
                ec2 = element
            else
                cloud=element.elements["CLOUD"]
                if cloud and cloud.text.upcase == host.upcase
                    ec2_deprecated = element
                end
            end
        }

        ec2 ||= ec2_deprecated

        if !ec2
            # If we don't find the EC2 site, and ONE just
            # knows about one EC2 site, let's use that
            if all_ec2_elements.size == 1
                ec2 = all_ec2_elements[0]
            else
                STDERR.puts(
                    "Cannot find EC2 element in deployment file "<<
                    "#{local_dfile} or couldn't find any EC2 site matching "<<
                    "one of the template.")
                exit(-1)
            end
        end

        ec2
    end

    # Retrive the vm information from the EC2 instance
    def parse_poll(instance)
        info =  "#{POLL_ATTRIBUTE[:usedmemory]}=0 " \
                "#{POLL_ATTRIBUTE[:usedcpu]}=0 " \
                "#{POLL_ATTRIBUTE[:nettx]}=0 " \
                "#{POLL_ATTRIBUTE[:netrx]}=0"

        if !instance.exists?
            info << " #{POLL_ATTRIBUTE[:state]}=#{VM_STATE[:deleted]}"
        else
            case instance.status
                when :pending
                    info << " #{POLL_ATTRIBUTE[:state]}=#{VM_STATE[:active]}"
                when :running
                    info<<" #{POLL_ATTRIBUTE[:state]}=#{VM_STATE[:active]}"<<
                        " IP=#{instance.ip_address}"
                when :'shutting-down', :terminated
                    info << " #{POLL_ATTRIBUTE[:state]}=#{VM_STATE[:deleted]}"
            end
        end

        info
    end

    # Execute an EC2 command
    # +deploy_id+: String, VM id in EC2
    # +ec2_action+: Symbol, one of the keys of the EC2 hash constant (i.e :run)
    def ec2_action(deploy_id, ec2_action)
        i = get_instance(deploy_id)

        begin
            i.send(EC2[ec2_action][:cmd])
        rescue => e
            STDERR.puts e.message
            exit(-1)
        end
    end

    # Generate the options for the given command from the xml provided in the
    #   template. The available options for each command are defined in the EC2
    #   constant
    def generate_options(action, xml, extra_params={})
        opts = extra_params || {}

        if EC2[action][:args]
            EC2[action][:args].each {|k,v|
                str = ec2_value(xml, k, &v[:proc])
                if str
                    tmp = opts
                    last_key = nil
                    v[:opt].split('/').each { |k|
                        tmp = tmp[last_key] if last_key
                        tmp[k] = {}
                        last_key = k
                    }
                    tmp[last_key] = str
                end
            }
        end

        opts
    end

    # Returns the value of the xml specified by the name or the default
    # one if it does not exist
    # +xml+: REXML Document, containing EC2 information
    # +name+: String, xpath expression to retrieve the value
    # +block+: Block, block to be applied to the value before returning it
    def ec2_value(xml, name, &block)
        value = value_from_xml(xml, name) || @defaults[name]
        if block_given? && value
            block.call(value)
        else
            value
        end
    end

    def value_from_xml(xml, name)
        if xml
            element = xml.elements[name]
            element.text.strip if element && element.text
        end
    end

    # Load the default values that will be used to create a new instance, if
    #   not provided in the template. These values are defined in the EC2_CONF
    #   file
    def load_default_template_values
        @defaults = Hash.new

        if File.exists?(EC2_DRIVER_DEFAULT)
            fd  = File.new(EC2_DRIVER_DEFAULT)
            xml = REXML::Document.new fd
            fd.close()

            return if !xml || !xml.root

            ec2 = xml.root.elements["EC2"]

            return if !ec2

            EC2.each {|action, hash|
                if hash[:args]
                    hash[:args].each { |key, value|
                        @defaults[key] = value_from_xml(ec2, key)
                    }
                end
            }
        end
    end

    # Retrive the instance from EC2
    def get_instance(id)
        begin
            instance = AWS.ec2.instances[id]
            if instance.exists?
                return instance
            else
                raise "Instance #{id} does not exist"
            end
        rescue => e
            STDERR.puts e.message
            exit(-1)
        end
    end
end

