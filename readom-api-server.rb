#!/usr/bin/env ruby
# encoding: utf-8

require 'rubygems'
require 'bundler'
Bundler.require

require 'json'

# === DataMapper Setup === #
DataMapper.setup(:default, ENV['DATABASE_URL'] || 'sqlite::memory:')
DataMapper::Model.raise_on_save_failure = true
DataMapper::Property::String.length(255)
#DataMapper::Logger.new($stdout, :debug)

class Item
  include DataMapper::Resource
  default_scope(:default).update(:order => [:id.asc])

  property :id, Serial
  property :title, String
  property :url, String
  property :by, String
  property :score, Integer
  property :time, DateTime

  property :top3, Boolean, :default => false
  property :top3push, Boolean, :default => false
  property :top3time, DateTime

  property :created_at, DateTime
  property :updated_at, DateTime
  property :deleted_at, ParanoidDateTime
  property :deleted, ParanoidBoolean, :default => false

  before :update, :log_before_update
  after :save, :log_after_save

  def to_json(json_opts=nil)
    json_obj.to_json(json_opts)
  end

  def json_obj
    {:id => id, :title => title, :url => url, :by => by, :score => score, :time => time.to_time.to_i}
  end

  def is_top3=(value)
    if value
      update(:top3 => value, :top3time => Time.now) unless top3time
    else
      update(:top3 => value)
    end
  end

  def log_before_update
    puts 'Before update id: %s, title: %s' % [id, title]
    true
  end

  def log_after_save
    puts 'After save id: %s, title: %s' % [id, title]
    true
  end

  class <<self
    alias :original_get :get

    def get_or_fetch(id)
      if item = Item.original_get(id) and item.title
        item
      else
        base_uri = 'https://hacker-news.firebaseio.com/v0/item/'
        firebase = Firebase::Client.new(base_uri)
        f_item = firebase.get(id).body

        if f_item['title']
          item = Item.create(:id => f_item['id']) unless item
          item.update :score => f_item['score'], :time => Time.at(f_item['time']), :title => f_item['title'], :url => f_item['url'], :by => f_item['by']

          item
        else
          nil
        end
      end
    end

    alias :get :get_or_fetch
  end
end

DataMapper.finalize
DataMapper.auto_upgrade!
# === end DataMapper === #

class CounterStore
  # store struct
  # - counter_dates: set : 20161201, 20121202
  # - counter_keys: set : pv, uv
  # - counters: hash : date_pv => 110, date_uv => 10
  # - counter_data: hll(pfadd/pfcount) : date_uv
  # UV key:
  # - IP?
  # - Device?
  # - User(Cookie)
  #    Server: get['Cookie_UV'] ? inc counter : (set-cookie[uv] & inc counter)
  #    Client: response['Cookie_UV'] ? 'save to default[uv]' : ""; request["Cookie_UV"] = default[uv]

  def initialize(url=ENV["REDIS_URL"])
    @url = url

    init_connection
  end

  def push(*arg)
    # arg: uvid, page
    ping

    uvid, page = arg

    t = Time.now.utc
    ts = t.strftime('%F')
    @redis.sadd 'CS:page_list', page

    ['_ALL', page].each do |pg|
      @redis.sadd 'CS:date_list:%s' % pg, ts
      @redis.hincrby 'CS:pv:%s' % pg, ts, 1
      @redis.hincrby 'CS:uv:%s' % pg, ts, 1 if @redis.pfadd 'CS:uv_hll:%s:%s' % [pg, ts], uvid # pfcount 'CS:uv_hll:%s:%s' % [pg, ts]
    end
  end

  def ping(ttl=3)
    begin
      @redis.ping
    rescue => e
      init_connection(ttl)
    end
  end

  def init_connection(ttl=3)
    begin
      @redis = Redis.new(url: @url)
      @redis.sadd 'CS:page_list', '_ALL'
      ping(ttl-1)
    rescue => e
      if ttl > 0
        sleep rand 5
        init_connection(ttl-1)
      end
    end
  end

  def report
    ping

    page_list = @redis.smembers 'CS:page_list'
    stat = page_list.sort.map do |pg|
      date_list = @redis.smembers 'CS:date_list:%s' %pg
      s = date_list.map do |dt|
        pv = @redis.hget 'CS:pv:%s' % pg, dt

        uv = @redis.pfcount 'CS:uv_hll:%s:%s' % [pg, dt]
        _uv = @redis.hget('CS:uv:%s' % pg, dt).to_i
        puts 'page: %s, date: %s, uv_hll: %d, uv: %d' % [pg, dt, uv, _uv] if uv != _uv
        @redis.hincrby 'CS:uv:%s' % pg, dt, (uv - _uv) if uv > _uv
        #@redis.hset 'CS_uv', dt, uv

        #[[:DATE, :PV, :UV], [dt, pv, uv]].transpose.to_h
        [dt, [[:PV, :UV], [pv, uv]].transpose.to_h]
      end.to_h.sort {|x,y| y[0] <=> x[0]}.to_h

      [pg, s]
    end.to_h
  end
end

$info = "Readom API Server"
$time = Time.now.utc.strftime('%FT%T%:z')
$counter = CounterStore.new

class ReadomAPIServer < Sinatra::Base

  enable :sessions
  enable :inline_templates

  configure {
    set :server, :puma
  }

  helpers do
    def counter_push(page)
      @uvid = request['R-UVID'] || request.cookies['R-UVID'] || request.env['HTTP_R_UVID'] || ''

      $counter.push @uvid, page
    end
  end

  helpers do
    include Rack::Utils
    alias_method :h, :escape_html
  end

  get "/news/v0/:board.:ext" do |board, ext|
    counter_push board

    base_uri = 'https://hacker-news.firebaseio.com/v0/'
    firebase = Firebase::Client.new(base_uri)
    list = firebase.get(board).body

    if board.to_sym == :topstories
      list[0..2].each do |item_id|
        item = Item.get(item_id)
        item.is_top3 = true if ! item.top3
      end
    end

    if limit = params['limit'] and max = limit.to_i - 1
      list = list.shuffle[0..max]
    end

    case ext
      when 'json'
        content_type 'application/json'
        list.map{|item_id| Item.get(item_id)}.to_json
      else
        content_type 'text/plain'
        list.join ','
    end
  end

  get '/news/v0/item/:item_id.:ext' do |item_id, ext|
    counter_push :item

    if item = Item.get(item_id)
      puts 'hit id %d' % [item_id]
    else
      puts 'miss id %d' % [item_id]
      item = {}
    end

    case ext
      when 'json'
        content_type 'application/json'
        item.to_json
      else
        content_type 'text/plain'
        item.to_json
    end
  end

  get '/top3.:ext' do |ext|
    if @items = Item.all(:top3 => true)
    else
      @items = []
    end

    case ext
      when 'html'
        content_type 'text/html'
        @title = 'Top-3 Items'
        haml :items
      when 'json'
        content_type 'application/json'
        @items.to_json
      else
        content_type 'application/json'
        @items.to_json
    end
  end

  get '/items.:ext' do |ext|
    if @items = Item.all
    else
      @items = []
    end

    case ext
      when 'html'
        content_type 'text/html'
        @title = 'All Items'
        haml :items
      when 'json'
        content_type 'application/json'
        @items.to_json
      else
        content_type 'application/json'
        @items.to_json
    end
  end

  get '/report.:ext' do |ext|
    counter_push :report

    case ext
      when 'json'
        content_type 'application/json'
        $counter.report.to_json
      when 'html'
        @report = $counter.report
        content_type 'text/html'
        haml :report
      else
        content_type 'text/plain'
        $counter.report.to_yaml
    end
  end

  get '/uvid.:ext' do |ext|
    counter_push :uvid

    case ext
      when 'json'
        content_type 'application/json'
        {:UVID => @uvid}.to_json
      else
        content_type 'text/plain'
        'UVID: %s' % @uvid
    end
  end

  def '/cleanup' do
    counter_push :cleanup
    result = {status: :noop}

    if count = Item.count > 10000
      Item.all(limit: 1000).destroy
      result = {status: :clean, count: Item.count, previous_count: count}
    end

    content_type 'application/json'
    result.to_json
  end

  get '/:ext?' do |ext|
    counter_push :_OTHERS

    case ext
      when 'json'
        content_type 'application/json'
        '{"status":"OK", "info":"%s", "time":"%s"}' % [$info, $time]
      when 'txt'
        content_type 'text/plain'
        'status: OK; info: %s; time: %s' % [$info, $time]
      else
        content_type 'text/html'
        haml :index
    end
  end
end

__END__

@@ layout
-# coding: UTF-8
!!!
%html(xml:lang='en' lang='en' xmlns='http://www.w3.org/1999/xhtml')
  %head
    %meta(content='text/html;charset=UTF-8' http-equiv='content-type')
    %meta(http-equiv="X-UA-Compatible" content="IE=edge")
    %meta(name="viewport" content="width=device-width, initial-scale=1")

    %link{:href => "css/bootstrap.min.css", :rel =>"stylesheet"}
    %link{:href => "css/bootstrap-theme.min.css", :rel =>"stylesheet"}
    <!--[if lt IE 9]>
    %script{:src => "https://oss.maxcdn.com/html5shiv/3.7.3/html5shiv.min.js"}
    %script{:src => "https://oss.maxcdn.com/respond/1.4.2/respond.min.js"}
    <![endif]-->

    %title Readom
  %body{:style => 'padding-top: 70px;'}
    %nav.navbar.navbar-default.navbar-fixed-top
      .container-fluid
        .navbar-header
          %button.navbar-toggle.collapsed{:'data-toggle' => "collapse", :'data-target' => "#navbar-collapse-1", :'aria-expanded' => "false", :type => 'button'}
            %span.sr-only Toggle navigation
            %span.icon-bar
            %span.icon-bar
            %span.icon-bar
          %a.navbar-brand
            %img{:alt => 'Brand', :src => 'images/logo-29.png'}

        .collapse.navbar-collapse#navbar-collapse-1
          %ul.nav.navbar-nav.nav-tabs
            %li.active{:role => "presentation"}
              %a{:href => '#'} Readom
            %li{:role => "presentation"}
              %a{:href => '/report.html'} Report
            %li{:role => "presentation"}
              %a{:href => '/items.html'} All Items
            %li{:role => "presentation"}
              %a{:href => '/top3.html'} Top-3 Items

    .container
      = yield
    %script{:src => "js/jquery-3.1.1.slim.min.js"}
    %script{:src => "js/bootstrap.min.js"}

@@ index
.jumbotron
  .row
    .col-md-2 Server
    .col-md-3
      = '%s' % $info
  .row
    .col-md-2 Status
    .col-md-3 OK
  .row
    .col-md-2 Start since
    .col-md-3
      = '%s' % $time

@@ report
.page-header
  %h1
    Trends
    %small
      %span.glyphicon.glyphicon-stats{:'aria-hidden' => "true"}

.row
  .table-responsive
    %table.table.table-striped
      %tr
        %th{:rowspan => 2} Date
        - @report.keys.each do |page|
          %th{:colspan => 2}
            = page
      %tr
        - @report.keys.each do |page|
          %th
            = 'PV'
          %th
            = 'UV'
      - @report['_ALL'].keys.each do |dt|
        %tr
          %td
            = dt
          - @report.keys.each do |page|
            - if @report[page][dt]
              %td
                = @report[page][dt][:PV]
              %td
                = @report[page][dt][:UV]
            - else
              %td -
              %td -

@@ items
.page-header
  %h1
    = @title || 'Items'
    %small
      %span.glyphicon.glyphicon-stats{:'aria-hidden' => "true"}
.row
  .table-responsive
    %table.table.table-striped
      %tr
        - [:id, :title, :url, :by, :score, :time, :top3, :top3push, :top3time].each do |key|
          %th
            = key
      - @items.each do |item|
        %tr
          - [:id, :title, :url, :by, :score, :time].each do |key|
            %td
              = item[key]
          - [:top3, :top3push].each do |key|
            %td
              = item[key] ? 'Y' : 'N'
          - [:top3time].each do |key|
            %td
              - if item[key]
                = "%s (%s)" % [item[key].to_time.strftime("%F %T %z"), item[key].to_time.ago_in_words]
