#!/usr/bin/env ruby
# encoding: utf-8

require 'rubygems'
require 'bundler'
Bundler.require

class ReadomAPIServer < Sinatra::Base

  enable :sessions

  configure {
    set :server, :puma
  }

  helpers do
    include Rack::Utils
    alias_method :h, :escape_html
  end

  get '/' do
    'Readom API Server'
  end
end
