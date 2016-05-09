require 'pathname'
require 'httparty'

module Neo4j
  module RakeTasks
    # Represents and manages a server installation at a specific path
    class ServerManager
      def initialize(path)
        @path = Pathname.new(path)
        FileUtils.mkdir_p(@path)
      end

      # MAIN COMMANDS

      def install(edition_string)
        version = version_from_edition(edition_string)
        puts "Installing neo4j-#{version}"

        return false if neo4j_binary_path.exist?

        archive_path = download_neo4j(version)
        extract!(archive_path)

        FileUtils.rm archive_path

        puts "Neo4j installed to: #{@path}"
      end

      def start(wait = true)
        system_or_fail(neo4j_command_path(start_argument(wait))).tap do
          @pid = pid_path.read.to_i
        end
      end

      def stop(timeout = nil)
        validate_is_system_admin!

        Timeout.timeout(timeout) do
          system_or_fail(neo4j_command_path(:stop))
        end
      rescue Timeout::Error
        puts 'Shutdown timeout reached, killing process...'
        Process.kill('KILL', @pid) if @pid
      end

      def console
        system_or_fail(neo4j_command_path(:console))
      end

      def shell
        not_started = !pid_path.exist?

        start if not_started

        system_or_fail(neo4j_shell_binary_path.to_s)

        stop if not_started
      end

      def info
        validate_is_system_admin!

        system_or_fail(neo4j_command_path(:info))
      end

      def restart
        validate_is_system_admin!

        system_or_fail(neo4j_command_path(:restart))
      end

      def reset
        validate_is_system_admin!

        stop

        delete_path = @path.join('data/graph.db/*')
        puts "Deleting all files matching #{delete_path}"
        FileUtils.rm_rf(Dir.glob(delete_path))

        delete_path = @path.join('data/log/*')
        puts "Deleting all files matching #{delete_path}"
        FileUtils.rm_rf(Dir.glob(delete_path))

        start
      end

      def self.change_password!
        puts 'This will change the password for a Neo4j server'

        address, old_password, new_password = prompt_for_address_and_passwords!

        body = change_password_request(address, old_password, new_password)
        if body['errors']
          puts "An error was returned: #{body['errors'][0]['message']}"
        else
          puts 'Password changed successfully! Please update your app to use:'
          puts 'username: neo4j'
          puts "password: #{new_password}"
        end
      end

      def config_auth_enabeled!(enabled)
        value = enabled ? 'true' : 'false'
        modify_config_file(
          'dbms.security.authorization_enabled' => value,
          'dbms.security.auth_enabled' => value)
      end

      def config_port!(port)
        puts "Config ports #{port} / #{port - 1}"

        if server_version >= '3.0.0'
          # These are not ideal, perhaps...
          modify_config_file('dbms.connector.https.enabled' => false,
                             'dbms.connector.http.enabled' => true,
                             'dbms.connector.http.address' => "0.0.0.0:#{port}",
                             'dbms.connector.https.address' => "localhost:#{port - 1}")
        else
          modify_config_file('org.neo4j.server.webserver.https.enabled' => false,
                             'org.neo4j.server.webserver.port' => port,
                             'org.neo4j.server.webserver.https.port' => port - 1)
        end
      end

      # END MAIN COMMANDS

      def modify_config_file(properties)
        contents = File.read(property_configuration_path)

        File.open(property_configuration_path, 'w') { |file| file << modify_config_contents(contents, properties) }
      end

      def modify_config_contents(contents, properties)
        properties.inject(contents) do |r, (property, value)|
          r.gsub(/^\s*(#\s*)?#{property}\s*=\s*(.+)/, "#{property}=#{value}")
        end
      end

      def self.class_for_os
        OS::Underlying.windows? ? WindowsServerManager : StarnixServerManager
      end

      def self.new_for_os(path)
        class_for_os.new(path)
      end

      protected

      def start_argument(wait)
        wait ? 'start' : 'start-no-wait'
      end

      def binary_command_path(binary_file)
        @path.join('bin', binary_file)
      end

      def neo4j_binary_path
        binary_command_path(neo4j_binary_filename)
      end

      def neo4j_command_path(command)
        neo4j_binary_path.to_s + " #{command}"
      end

      def neo4j_shell_binary_path
        binary_command_path(neo4j_shell_binary_filename)
      end

      def property_configuration_path
        if server_version >= '3.0.0'
          @path.join('conf', 'neo4j.conf')
        else
          @path.join('conf', 'neo4j-server.properties')
        end
      end

      def validate_is_system_admin!
        nil
      end

      def system_or_fail(command)
        system(command.to_s) ||
          fail("Unable to run: #{command}")
      end

      def version_from_edition(edition_string)
        edition_string.downcase.gsub(/-([a-z\-]+)$/) do
          puts "Retrieving #{$1} version..."

          version = neo4j_versions[$1]

          fail "Invalid version identifier: #{$1}" if !neo4j_versions.key?($1)
          fail "There is not currently a version for #{$1}" if version.nil?

          puts "#{$1.capitalize} version is: #{version}"

          "-#{version}"
        end
      end

      def pid_path
        if server_version >= '3.0.0'
          @path.join('run/neo4j.pid')
        else
          @path.join('data/neo4j-service.pid')
        end
      end

      private

      NEO4J_VERSIONS_URL = 'https://raw.githubusercontent.com/neo4jrb/neo4j-rake_tasks/master/neo4j_versions.yml'

      def server_version
        kernel_jar_path = Dir.glob(@path.join('lib/neo4j-kernel-*.jar'))[0]
        kernel_jar_path.match(/neo4j-kernel-([\d\.]+)\.jar$/)[1]
      end

      def neo4j_versions
        require 'open-uri'
        require 'yaml'

        YAML.load(open(NEO4J_VERSIONS_URL).read)
      end

      def download_neo4j(version)
        tempfile = Tempfile.open('neo4j-download', encoding: 'ASCII-8BIT')

        url = download_url(version)

        status = HTTParty.head(url).code
        unless (200...300).include?(status)
          fail "#{version} is not available to download"
        end

        tempfile << HTTParty.get(url)
        tempfile.flush

        tempfile.path
      end

      # POSTs to an endpoint with the form required to change a Neo4j password
      # @param [String] address
      #                 The server address, with protocol and port,
      #                 against which the form should be POSTed
      # @param [String] old_password
      #                 The existing password for the "neo4j" user account
      # @param [String] new_password
      #                 The new password you want to use. Shocking, isn't it?
      # @return [Hash]  The response from the server indicating success/failure.
      def self.change_password_request(address, old_password, new_password)
        uri = URI.parse("#{address}/user/neo4j/password")
        response = Net::HTTP.post_form(uri,
                                       'password' => old_password,
                                       'new_password' => new_password)
        JSON.parse(response.body)
      end

      def self.prompt_for(prompt, default = false)
        puts prompt
        print "#{default ? '[' + default.to_s + ']' : ''} > "
        result = STDIN.gets.chomp
        result = result.blank? ? default : result
        result
      end

      def prompt_for_address_and_passwords!
        address = prompt_for(
          'Enter IP address / host name without protocal and port',
          'http://localhost:7474')

        old_password = prompt_for(
          'Input current password. Leave blank for a fresh installation',
          'neo4j')

        new_password = prompt_for 'Input new password.'
        fail 'A new password is required' if new_password == false

        [address, old_password, new_password]
      end
    end
  end
end
