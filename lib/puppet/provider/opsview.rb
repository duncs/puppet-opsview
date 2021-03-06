begin
  require 'rest-client'
  require 'json'
rescue LoadError => e
  nil
end
require 'yaml'

class Puppet::Provider::Opsview < Puppet::Provider
  @@errorOccurred = 0

  def create
    @property_hash[:ensure] = :present
    self.class.resource_type.validproperties.each do |property|
      if val = resource.should(property)
        @property_hash[property] = val
      end
    end
  end

  def errorOccurred
    self.class.errorOccurred
  end
  
  def self.errorOccurred
    return true if @@errorOccurred > 0
    return false
  end

  def delete
    @property_hash[:ensure] = :absent
  end

  def exists?
    @property_hash[:ensure] != :absent
  end

  private

  def put(body)
    self.class.put(body)
  end

  def self.put(body)
    if @@errorOccurred > 0
      Puppet.warning "put: Problem talking to Opsview server; ignoring Opsview config"
      return
    end

    url = [ config["url"], "config/#{@req_type.downcase}" ].join("/")
    begin
      response = RestClient.put url, body, :x_opsview_username => config["username"], :x_opsview_token => token, :content_type => :json, :accept => :json, :timeout => config["timeout"]
    rescue
      @@errorOccurred = 1
      Puppet.warning "put_1: Problem sending data to Opsview server; " + $!.inspect + "\n====\n" + url + "\n====\n" + body
      return
    end

    begin
      responseJson = JSON.parse(response)
    rescue
      @@errorOccurred = 1
      Puppet.warning "put_2: Problem talking to Opsview server; ignoring Opsview config - " + $!.inspect
      return
    end

    # if we get here, all should be ok, so make sure we mark as such.
    @@errorOccurred = 0
  end

  def config
    self.class.config
  end

  def self.config
    Puppet.debug "Accessing config"
    @config ||= get_config
  end

  def self.get_config
    Puppet.debug "Loading in Opsview configuration"
    config_file = "/etc/puppet/opsview.conf"
    # Load the Opsview config
    begin
      conf = YAML.load_file(config_file)
    rescue
      raise Puppet::ParseError, "Could not parse YAML configuration file " + config_file + " " + $!.inspect
    end

    if conf["username"].nil? or conf["password"].nil? or conf["url"].nil? or conf["timeout"].nil?
      raise Puppet::ParseError, "Config file must contain URL, username, password and timeout fields."
    end

    Puppet.debug "conf(url)="+conf["url"]
    Puppet.debug "conf(username)="+conf["username"]
    Puppet.debug "conf(password)="+conf["password"].gsub(/\w/,'x')
    Puppet.debug "conf(timeout)="+conf["timeout"].to_s

    conf
  end

  def token
    self.class.token
  end

  def self.token
    Puppet.debug "Accessing token"
    @token ||= get_token
  end

  def self.get_token
    Puppet.debug "Fetching Opsview token"
    post_body = { "username" => config["username"],
                  "password" => config["password"] }.to_json

    url = [ config["url"], "login" ].join("/")
    timeout = config["timeout"].to_s

    Puppet.debug "Using Opsview url: "+url
    Puppet.debug "using post: username:"+config["username"]+" password:"+config["password"].gsub(/\w/,'x')+" timeout:"+config["timeout"].to_s

    if Puppet[:debug]
      Puppet.debug "Logging RestClient calls to: /tmp/puppet_restclient.log"
      RestClient.log='/tmp/puppet_restclient.log'
    end

    begin
      response = RestClient.post url, post_body, :content_type => :json, :timeout => config["timeout"].to_s
    rescue
      @@errorOccurred = 1
      Puppet.warning "Problem getting token from Opsview server; " + $!.inspect
      return
    end

    case response.code
    when 200
      Puppet.debug "Response code: 200"
    else
      @@errorOccurred = 1
      Puppet.warning "Unable to log in to Opsview server; HTTP code " + response.code
      return
    end

    received_token = JSON.parse(response)['token']
    Puppet.debug "Got token: "+received_token
    received_token
  end

  def do_reload_opsview
    self.class.do_reload_opsview
  end

  def self.get_reload_status
    url = [ config["url"], "reload" ].join("/")

    Puppet.debug "Getting Opsview reload status"

    response = RestClient.get url, :x_opsview_username => config["username"], :x_opsview_token => token, :content_type => :json, :accept => :json, :timeout => config["timeout"].to_s

    case response.code
    when 200
        # all is ok at this pount
    when 401
        @@errorOccurred = 1
        raise "Login failed: " + response.code
    else
        @@errorOccurred = 1
        raise "Was not able to fetch Opsview status: HTTP code: " + response.code
    end
	
    Puppet.debug "Current Reload info: " + response.inspect
    responseJson = JSON.parse(response)
    return responseJson
  end

  def self.do_reload_opsview
    url = [ config["url"], "reload" ].join("/")

    if @@errorOccurred > 0
      Puppet.warning "reload_opsview: Problem talking to Opsview server; ignoring Opsview config"
      return
    end

    last_reload = self.get_reload_status

    if last_reload["server_status"].to_i > 0
        Puppet.notice "Opsview reload already in progress; continuing"
        return
    end

    Puppet.debug "Last reload at: " + last_reload["lastupdated"]
    Puppet.info "Initiating Opsview reload"

    # Start the reload in a forked process, then keep fetching the current 
    # status in the parent
    # Do it this way as the API doesn't currently do asynchronus reloads and
    # the rest client may time out if reloads take too long
    fork do
        RestClient.post url, '', :x_opsview_username => config["username"], :x_opsview_token => token, :content_type => :json, :accept => :json
        exit
    end

    Puppet.debug "Entering polling"

    end_time = Time.now.to_i+config["timeout"]

    # now loop every few seconds or so to fetch the current status to see
    # when the reload completes.  Respect the timeout if the reload takes 
    # too long
    loop do
        sleep(2)
        Puppet.debug "Polling for reload status"
        this_reload = self.get_reload_status
        break if this_reload["server_status"].to_i == 0 && this_reload["lastupdated"] != last_reload["lastupdated"] 
        break if Time.now.to_i >= end_time
    end
    
    # hit timeout so alert and mark error
    if Time.now.to_i >= end_time
        Puppet.warning "Reload did not complete within configured timeout ("+config["timeout"].to_s+" seconds)"
        @@errorOccurred = 1
    else
        Puppet.info "Opsview reload completed"
    end

    # reap any children
    Puppet.debug("Reaping Opsview reload child")
    Process.wait
  end

  def get_resource(name = nil)
    self.class.get_resource(name)
  end

  def get_resources
    self.class.get_resources
  end

  def self.get_resource(name = nil)
    if @@errorOccurred > 0
      Puppet.warning "get_resource: Problem talking to Opsview server; ignoring Opsview config"
      return
    end

    if name.nil?
      raise "Did not specify a node to look up."
    else
      url = URI.escape( [ config["url"], "config/#{@req_type.downcase}?s.name=#{name}" ].join("/") )
    end

    begin
      response = RestClient.get url, :x_opsview_username => config["username"], :x_opsview_token => token, :content_type => :json, :accept => :json, :params => {:rows => :all}, :timeout => config["timeout"].to_s
    rescue
      @@errorOccurred = 1
      Puppet.warning "get_resource: Problem talking to Opsview server; ignoring Opsview config: " + $!.inspect
    end

    begin
      responseJson = JSON.parse(response)
    rescue
      raise Puppet::Error,"Could not parse the JSON response from Opsview: " + response
    end

    obj = responseJson['list'][0]

    obj
  end

  def self.get_resources
    url = [ config["url"], "config/#{@req_type.downcase}" ].join("/")

    if @@errorOccurred > 0
       Puppet.warning "get_resources: Problem talking to Opsview server; ignoring Opsview config"
      return
    end

    begin
      response = RestClient.get url, :x_opsview_username => config["username"], :x_opsview_token => token, :content_type => :json, :accept => :json, :params => {:rows => :all}, :timeout => config["timeout"].to_s
    rescue
      @@errorOccurred = 1
      Puppet.warning "get_resource: Problem talking to Opsview server; ignoring Opsview config: " + $!.inspect
    end

    begin
      responseJson = JSON.parse(response)
    rescue
      raise "Could not parse the JSON response from Opsview: " + response
    end

    objs = responseJson["list"]

    objs
  end
end
