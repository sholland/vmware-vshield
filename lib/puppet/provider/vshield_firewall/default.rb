# Copyright (C) 2013 VMware, Inc.
provider_path = Pathname.new(__FILE__).parent.parent
require File.join(provider_path, 'vshield')

Puppet::Type.type(:vshield_firewall).provide(:default, :parent => Puppet::Provider::Vshield) do
  @doc = 'Manages vShield Firewall Rules.'

  def populate_fw_elements
    ipset_url       = "/api/2.0/services/ipset/scope/#{vshield_edge_moref}" 
    @cur_ipsets     = ensure_array( nested_value(get("#{ipset_url}"), ['list', 'ipset' ]) )
    
    app_url         = "/api/2.0/services/application/scope/#{vshield_edge_moref}"
    @cur_apps       = ensure_array( nested_value(get("#{app_url}"), ['list', 'application' ]) )

    grp_url  = "/api/2.0/services/applicationgroup/scope/#{vshield_edge_moref}"
    @cur_app_groups = ensure_array( nested_value(get("#{grp_url}"), ['list', 'applicationGroup' ]) )
  end

  def exists?
    fw_url  = "/api/3.0/edges/#{vshield_edge_moref}/firewall/config"
    results = ensure_array( nested_value(get("#{fw_url}"), [ 'firewall', 'firewallRules', 'firewallRule' ]) )

    # grab ipsets,  apps ( services ), and app groups ( service groups ) for create/flush
    populate_fw_elements

    # A single result is a hash, while multiple results is an array.
    @fw_rule = results.find {|rule| rule['name'] == resource[:name] and rule['ruleType'] == 'user' }

    # populate source,destination and service with [] entries if they are nil
    populate_properties
    @fw_rule
  end

  def populate_properties
    if @fw_rule
      [ 'source', 'destination' ].each do |prop|
        if not @fw_rule[prop] 
          @fw_rule[prop] = {}
          @fw_rule[prop]['groupingObjectId'] = ensure_array(@fw_rule[prop]['groupingObjectId'])
        end
      end
      if not @fw_rule['application']
        @fw_rule['application'] = {}
        @fw_rule['application']['applicationId'] = ensure_array(@fw_rule['application']['applicationId'])
      end
    end
  end

  def replace_properties
    @fw_rule['action']                          = resource[:action]
    @fw_rule['source']['groupingObjectId']      = ipset_sub_id('source') if resource[:source]
    @fw_rule['destination']['groupingObjectId'] = ipset_sub_id('destination') if resource[:destination]
    @fw_rule['application']['applicationId']    = app_sub_id
  end

  def create
    @fw_rule = {}
    populate_properties
    replace_properties
    @fw_rule['name']                            = resource[:name]
    data                                      ||= {}
    data[:firewallRule ]                        = @fw_rule.reject{|k,v| v.nil? }
    post("/api/3.0/edges/#{vshield_edge_moref}/firewall/config/rules", { :firewallRules => data })
  end

  def destroy
    Puppet.notice("delete Not implemented")
  end

  def source
    source = []
    @fw_rule['source']['groupingObjectId'].each do |id|
      ipset = @cur_ipsets.find{|x| x['objectId'] == id}
      source << ipset['name'] if ipset and ipset['name']
    end
    source.sort
  end

  def source=(src=resource[:source])
    @pending_changes = true
  end

  def destination
    dest = []
    @fw_rule['destination']['groupingObjectId'].each do |id|
      ipset = @cur_ipsets.find{|x| x['objectId'] == id}
      dest << ipset['name'] if ipset and ipset['name']
    end
    dest.sort
  end

  def destination=(dest=resource[:destination])
    @pending_changes = true
  end

  def service_application
    service_apps = []
    @fw_rule['application']['applicationId'].each do |id|
      app = @cur_apps.find{|x| x['objectId'] == id and x['objectId'] =~ /^application-/ }
      service_apps << app['name'] if app and app['name']
    end
    service_apps.sort
  end

  def service_application=(service=resource[:service_application])
    @pending_changes = true
  end

  def service_group
    service_groups = []
    @fw_rule['application']['applicationId'].each do |id|
      app = @cur_app_groups.find{|x| x['objectId'] == id and x['objectId'] =~ /^applicationgroup-/ }
      service_groups << app['name'] if app and app['name']
    end
    service_groups.sort
  end

  def service_group=(service=resource[:service_group])
    @pending_changes = true
  end

  def action
    @fw_rule['action']
  end

  def action=(action=resource[:action])
    @pending_changes = true
  end

  #def log
  #end

  #def log=
  #  @pending_changes = true
  #end

  def ipset_sub_id(src_or_dest)
    ids = []
    resource[:"#{src_or_dest}"].each do |name|
      case name
      when /^(external|internal|vse)$/
        ids << name
      when /^vnic[0-9]$/
        vnic_num = name.sub('vnic','')
        ids << "vnic-index-#{vnic_num}"
      else
        ipset = @cur_ipsets.find{|x| x['name'] == name}
        msg   = "ipset: #{name} does not exist for resource: #{resource[:name]},
                 property: #{resource[:"#{src_or_dest}"].inspect}"
        raise Puppet::Error, "#{msg}" if ipset.nil?
        ids << ipset['objectId']
      end
    end
    ids
  end

  def app_sub_id
    ids = []
    resource[:service_application] = [] if resource[:service_application] == [ 'any' ]
    resource[:service_application].each do |name|
      service_app = @cur_apps.find{|x| x['name'] == name}
      app_msg     = "Service: #{name} does not exist for #{resource[:name]}"
      raise Puppet::Error, "#{app_msg}" if service_app.nil?
      ids << service_app['objectId']
    end
    resource[:service_group] = [] if resource[:service_group] == [ 'any' ]
    resource[:service_group].each do |name|
      service_group = @cur_app_groups.find{|x| x['name'] == name}
      group_msg     = "Service Group: #{name} does not exist for #{resource[:name]}"
      raise Puppet::Error, "#{group_msg} " if service_group.nil?
      ids << service_group['objectId']
    end
    ids.sort
  end

  def flush
    if @pending_changes
      raise Puppet::Error, "Firewall Rule #{resource[:name]} was not found" unless @fw_rule
      replace_properties
      data                                        = {}
      data[:firewallRule ]                        = @fw_rule.reject{|k,v| v.nil? }
      
      Puppet.debug("Updating fw rule: #{resource[:name]}")
      put("api/3.0/edges/#{vshield_edge_moref}/firewall/config/rules/#{@fw_rule['id']}", data )
    end
  end
end
