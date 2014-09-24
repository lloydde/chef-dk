#
# Copyright:: Copyright (c) 2014 Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef-dk/authenticated_http'
require 'chef-dk/policyfile_compiler'
require 'chef-dk/policyfile/uploader'

module ChefDK
  module PolicyfileServices
    class Push

      attr_reader :root_dir
      attr_reader :config
      attr_reader :policy_group
      attr_reader :ui

      def initialize(policyfile: nil, ui: nil, policy_group: nil, config: nil, root_dir: nil)
        @root_dir = root_dir
        @policyfile_relative_path = policyfile
        @ui = ui
        @config = config
        @policy_group = policy_group

        @http_client = nil
        @storage_config = nil
        @policy_data = nil
      end

      def policyfile_relative_path
        @policyfile_relative_path || "Policyfile.rb"
      end

      def policyfile_path
        File.expand_path(policyfile_relative_path, root_dir)
      end

      def lockfile_relative_path
        policyfile_relative_path.gsub(/\.rb\Z/, '') + ".lock.json"
      end

      def lockfile_path
        File.expand_path(lockfile_relative_path, root_dir)
      end

      def http_client
        @http_client ||= ChefDK::AuthenticatedHTTP.new(config.chef_server_url,
                                                       signing_key_filename: config.client_key,
                                                       client_name: config.node_name)
      end

      def policy_data
        @policy_data ||= FFI_Yajl::Parser.parse(IO.read(lockfile_path))
      rescue => error
        raise PolicyfilePushError.new("Error reading lockfile #{lockfile_path}", error)
      end

      def storage_config
        @storage_config ||= ChefDK::Policyfile::StorageConfig.new.use_policyfile_lock(lockfile_path)
      end

      def uploader
        ChefDK::Policyfile::Uploader.new(policyfile_lock, policy_group, ui: ui, http_client: http_client)
      end

      def run
        unless File.exist?(lockfile_path)
          raise LockfileNotFound, "No lockfile at #{lockfile_path} - you need to run `install` before `push`"
        end

        validate_lockfile
        write_updated_lockfile
        upload_policy

      end

      def policyfile_lock
        @policyfile_lock || validate_lockfile
      end

      private

      def upload_policy
        uploader.upload
      rescue => error
        raise PolicyfilePushError.new("Failed to upload policy to policy group #{policy_group}", error)
      end

      def write_updated_lockfile
        File.open(lockfile_path, "w+") do |f|
          f.print(FFI_Yajl::Encoder.encode(policyfile_lock.to_lock, pretty: true ))
        end
      end

      def validate_lockfile
        return @policyfile_lock if @policyfile_lock
        @policyfile_lock = ChefDK::PolicyfileLock.new(storage_config).build_from_lock_data(policy_data)
        # TODO: enumerate any cookbook that have been updated
        @policyfile_lock.validate_cookbooks!
        @policyfile_lock
      rescue => error
        raise PolicyfilePushError.new("Invalid lockfile data", error)
      end

    end
  end
end
