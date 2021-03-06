#!/usr/bin/env ruby

require 'selenium-webdriver'
require 'aws-sdk'
require 'parseconfig'
require 'onelogin/ruby-saml'
require 'base64'
require 'highline'
require 'json'

BASE_URL = 'https://shibboleth.umich.edu/idp/profile/SAML2/Unsolicited/SSO?providerId=urn:amazon:webservices'.freeze
AWS_ROLE = 'https://aws.amazon.com/SAML/Attributes/Role'.freeze
AWS_CONFIG_FILE = '/.aws/credentials'.freeze
REGION = 'us-east-2'.freeze
OUTPUT_FORMAT = 'json'.freeze

cli = HighLine.new

begin
  # Parse arguments
  session_duration = ARGV[0]    # if not set the aws default is used (1 hour)

  # Get the federated credentials from the user
  print 'Uniqname: '
  uid = STDIN.gets.chomp
  password = cli.ask('Password:  ') { |q| q.echo = '*' }
  print ''

  driver = Selenium::WebDriver.for :firefox
  driver.navigate.to BASE_URL

  wait = Selenium::WebDriver::Wait.new(timeout: 60) # seconds
  wait.until { driver.find_element(id: 'login') }

  element = driver.find_element(:id, 'login')
  element.send_keys uid
  element = driver.find_element(:id, 'password')
  element.send_keys password
  element = driver.find_element(:id, 'loginSubmit')
  element.click

  sleep 3

  wait.until { driver.find_element(id: 'duo_iframe') }
  driver.switch_to.frame 'duo_iframe'
  wait.until { driver.find_element(name: 'passcode') }
  begin
    driver.find_element(class: 'used-automatically')
    puts 'Sending Duo request...'
  rescue
    puts "\nEnter a passcode or select one of the following options:"
    puts ' 1. Duo Push to default device'
    print 'Passcode or option (1): '
    duo_code = STDIN.gets.chomp
    puts ''
    if duo_code == '1'
      puts 'Sending Duo push notification...'
      driver.find_element(:css, 'button.positive.auth-button').click
    else
      passcode_button = driver.find_element(class: 'passcode-label')
      passcode_button.find_element(:css, 'button.positive.auth-button').click
      passcode_input = driver.find_element(class: 'passcode-input')
      passcode_input.send_keys duo_code
      passcode_button.find_element(:css, 'button.positive.auth-button').click
    end
  end

  driver.switch_to.default_content
  wait.until { driver.find_element(name: 'SAMLResponse') }
  assertion = driver.find_element(:name, 'SAMLResponse').attribute('value')

  driver.quit

  saml = OneLogin::RubySaml::Response.new(Base64.decode64(assertion))

  aws_roles = []
  saml.attributes.multi(AWS_ROLE).sort.each do |role|
    (role_arn, principal_arn) = role.split(',')
    aws_roles.push(principal_arn: principal_arn,
                   role_arn: role_arn)
  end

  if aws_roles.length > 1
    i = 0
    puts 'Please choose the role you would like to assume:'
    aws_roles.each do |aws_role|
      print '[', i, ']: ', aws_role[:role_arn]
      puts
      i += 1
    end

    print 'Selection: '
    selection = STDIN.gets.chomp.to_i

    puts "you selected #{selection}, #{aws_roles[selection][:role_arn]}"

    if selection > aws_roles.length - 1
      puts 'You selected an invalid role index, please try again'
      exit(0)
    end

    principal_arn = aws_roles[selection][:principal_arn]
    role_arn = aws_roles[selection][:role_arn]
  else
    principal_arn = aws_roles[0][:principal_arn]
    role_arn = aws_roles[0][:role_arn]
  end

  sts = Aws::STS::Client.new(region: REGION)
  print 'generating token'
  token = sts.assume_role_with_saml(role_arn: role_arn,
                                    principal_arn: principal_arn,
                                    saml_assertion: assertion,
                                    duration_seconds: session_duration)

  # Write the AWS STS token into the AWS credential file
  puts Dir.home
  filename = Dir.home + AWS_CONFIG_FILE

  # Read in the existing config file
  config = ParseConfig.new(filename)
  config.import_config

  # Put the credentials into a specific profile instead of clobbering
  # the default credentials
  config.add_to_group('saml', 'output', OUTPUT_FORMAT)
  config.add_to_group('saml', 'region', REGION)
  config.add_to_group('saml', 'aws_access_key_id', token.credentials.access_key_id)
  config.add_to_group('saml', 'aws_secret_access_key', token.credentials.secret_access_key)
  config.add_to_group('saml', 'aws_session_token', token.credentials.session_token)

  # Write the updated config file
  file = File.open(filename, 'w')
  config.write(file, quoted=false)
  file.close

  # Give the user some basic info as to what has just happened
  puts "\n\n----------------------------------------------------------------"
  puts 'Your new access key pair has been stored in the AWS configuration file under the saml profile.'
  puts "Note that it will expire at #{token.credentials.expiration}."
  puts 'After this time you may safely rerun this script to refresh your access key pair.'
  puts 'To use this credential call the AWS CLI with the --profile option (e.g. aws --profile saml ec2 describe-instances).'
  puts "----------------------------------------------------------------\n\n"

rescue => e
  puts "Exception Class: #{ e.class.name }"
  puts "Exception Message: #{ e.message }"
  puts "Exception Backtrace: #{ e.backtrace }"
end
