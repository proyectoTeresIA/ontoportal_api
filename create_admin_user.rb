#!/usr/bin/env ruby

# Script to create the first admin user
require 'bundler/setup'
require 'ontologies_linked_data'
require 'ncbo_annotator'
require 'ncbo_ontology_recommender'
require 'ncbo_cron'
require_relative 'config/config'
require_relative 'config/environments/development'

# Create an admin role if it doesn't exist
admin_role = LinkedData::Models::Users::Role.find("ADMINISTRATOR").first
unless admin_role
  admin_role = LinkedData::Models::Users::Role.new
  admin_role.role = "ADMINISTRATOR"
  admin_role.save
end

# Check if admin user already exists
admin_user = LinkedData::Models::User.find("admin").first

if admin_user
  # Admin user already exists, show existing API key
  admin_user.bring(:username, :email, :apikey)
  puts "Admin user already exists!"
  puts "Username: #{admin_user.username}"
  puts "Email: #{admin_user.email}"
  puts "API Key: #{admin_user.apikey}"
  puts ""
  puts "You can use this API key to authenticate requests to the API."
  puts "Example: curl 'http://localhost:9393/ontologies?apikey=#{admin_user.apikey}'"
else
  # Create the admin user
  admin_user = LinkedData::Models::User.new({
    username: "admin",
    email: "admin@example.org",
    password: ENV['ADMIN_PASSWORD'] || 'admin123',
    role: [admin_role]
  })

  if admin_user.valid?
    admin_user.save
    admin_user.bring(:apikey)
    puts "Admin user created successfully!"
    puts "Username: #{admin_user.username}"
    puts "Email: #{admin_user.email}"
    puts "API Key: #{admin_user.apikey}"
    puts ""
    puts "You can now use this API key to authenticate requests to the API."
    puts "Example: curl 'http://localhost:9393/ontologies?apikey=#{admin_user.apikey}'"
  else
    puts "Error creating admin user:"
    puts admin_user.errors
  end
end
