# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "stud/interval"
require "socket" # for Socket.gethostname
require "puma/server"
require "puma/minissl"

class Puma::Server
  # ensure this method doesn't mess up our vanilla request
  def normalize_env(env, client); end
end

# This output opens a web server and listens to HTTP requests,
# converting them to LogStash::Event instances.
#
class LogStash::Inputs::Http < LogStash::Inputs::Base
  config_name "http"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain"

  # Which host or ip to bind to
  config :host, :validate => :string, :default => "0.0.0.0"

  # Which TCP port to bind to
  config :port, :validate => :number, :default => 8080

  # Maximum number of threads to use
  config :threads, :validate => :number, :default => 4

  # SSL Configurations
  #
  # Enable SSL
  config :ssl, :validate => :boolean, :default => false

  # The JKS keystore to validate the client's certificates
  config :keystore, :validate => :path

  #TODO: config :cacert, :validate => :path

  # Set the truststore password
  config :keystore_password, :validate => :password

  # useless headers puma adds to the requests
  # mostly due to rack compliance
  REJECTED_HEADERS = ["puma.socket", "rack.hijack?", "rack.hijack", "rack.url_scheme", "rack.after_reply", "rack.version", "rack.errors", "rack.multithread", "rack.multiprocess", "rack.run_once", "SCRIPT_NAME", "QUERY_STRING", "SERVER_PROTOCOL", "SERVER_SOFTWARE", "GATEWAY_INTERFACE"]

  RESPONSE_HEADERS = {'Content-Type' => 'text/plain'}

  public
  def register
    @server = ::Puma::Server.new(nil) # we'll set the rack handler later
    if @ssl
      if @keystore.nil? || @keystore_password.nil?
        raise(LogStash::ConfigurationError, "Settings :keystore and :keystore_password are required because :ssl is enabled.")
      end
      ctx = Puma::MiniSSL::Context.new
      ctx.keystore = @keystore
      ctx.keystore_pass = @keystore_password.value
      @server.add_ssl_listener(@host, @port, ctx)
    else
      @server.add_tcp_listener(@host, @port)
    end
    @server.min_threads = 0
    @server.max_threads = @threads
  end # def register

  def run(queue)
    @server.app = Proc.new do |req|
      begin
        REJECTED_HEADERS.each {|k| req.delete(k) }
        req = lowercase_keys(req)
        body = req.delete("rack.input")
        @codec.decode(body.read) do |event|
          event["headers"] = req
          decorate(event)
          queue << event
        end
        ['200', RESPONSE_HEADERS, ['ok']]
      rescue => e
        @logger.error("unable to process event #{req.inspect}. exception => #{e.inspect}")
        ['500', RESPONSE_HEADERS, ['internal error']]
      end
    end
    @server.run.join
  end # def run

  private
  def lowercase_keys(hash)
    new_hash = {}
    hash.each_pair do |k,v|
      new_hash[k.downcase] = v
    end
    new_hash
  end

  public
  def teardown
    if @server
      @server.stop(true)
      begin
        @server.binder.close if @server.binder
      rescue IOError
      end
    end
  end

end # class LogStash::Inputs::Http
