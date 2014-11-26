require "spec_helper"
require "rspec_api_documentation/dsl"
require "cgi"

resource "Events", :type => [:api, :legacy_api] do
  DOCUMENTED_EVENT_TYPES = %w[app.crash audit.app.update audit.app.create audit.app.delete-request audit.space.create audit.space.update audit.space.delete-request audit.service.create audit.service.update audit.service.delete]
  let(:admin_auth_header) { admin_headers["HTTP_AUTHORIZATION"] }
  authenticated_request

  before do
    3.times do
      VCAP::CloudController::Event.make
    end
  end

  let(:guid) { VCAP::CloudController::Event.first.guid }

  field :guid, "The guid of the event.", required: false
  field :type, "The type of the event.", required: false, readonly: true, valid_values: DOCUMENTED_EVENT_TYPES, example_values: %w[app.crash audit.app.update]
  field :actor, "The GUID of the actor.", required: false, readonly: true
  field :actor_type, "The actor type.", required: false, readonly: true, example_values: %w[user app]
  field :actor_name, "The name of the actor.", required: false, readonly: true
  field :actee, "The GUID of the actee.", required: false, readonly: true
  field :actee_type, "The actee type.", required: false, readonly: true, example_values: %w[space app]
  field :actee_name, "The name of the actee.", required: false, readonly: true
  field :timestamp, "The event creation time.", required: false, readonly: true
  field :metadata, "The additional information about event.", required: false, readonly: true, default: {}
  field :space_guid, "The guid of the associated space.", required: false, readonly: true
  field :organization_guid, "The guid of the associated organization.", required: false, readonly: true

  standard_model_list(:event, VCAP::CloudController::EventsController)
  standard_model_get(:event)

  get "/v2/events" do
    standard_list_parameters VCAP::CloudController::EventsController

    let(:test_app) { VCAP::CloudController::App.make }
    let(:test_user) { VCAP::CloudController::User.make }
    let(:test_user_email) { "user@email.com" }
    let(:test_space) { VCAP::CloudController::Space.make }
    let(:test_service) { VCAP::CloudController::Service.make }
    let(:app_request) do
      {
        "name" => "new",
        "instances" => 1,
        "memory" => 84,
        "state" => "STOPPED",
        "environment_json" => { "super" => "secret" }
      }
    end
    let(:space_request) do
      {
        "name" => "outer space"
      }
    end
    let(:droplet_exited_payload) do
      {
        "instance" => 0,
        "index" => 1,
        "exit_status" => "1",
        "exit_description" => "out of memory",
        "reason" => "crashed"
      }
    end
    let(:expected_app_request) do
      expected_request = app_request
      expected_request["environment_json"] = "PRIVATE DATA HIDDEN"
      expected_request
    end

    let(:app_event_repository) do
      VCAP::CloudController::Repositories::Runtime::AppEventRepository.new
    end

    let(:space_event_repository) do
      VCAP::CloudController::Repositories::Runtime::SpaceEventRepository.new
    end

    let(:service_event_repository) do
      security_context = double(:security_context, current_user: test_user, current_user_email: test_user_email)
      VCAP::CloudController::Repositories::Services::EventRepository.new(security_context)
    end

    example "List App Create Events" do
      app_event_repository.record_app_create(test_app, test_app.space, test_user, test_user_email, app_request)

      client.get "/v2/events?q=type:audit.app.create", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "user",
                               :actor => test_user.guid,
                               :actor_name => test_user_email,
                               :actee_type => "app",
                               :actee => test_app.guid,
                               :actee_name => test_app.name,
                               :space_guid => test_app.space.guid,
                               :metadata => { "request" => expected_app_request }
    end

    example "List App Exited Events" do
      app_event_repository.create_app_exit_event(test_app, droplet_exited_payload)

      client.get "/v2/events?q=type:app.crash", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "app",
                               :actor => test_app.guid,
                               :actor_name => test_app.name,
                               :actee_type => "app",
                               :actee => test_app.guid,
                               :actee_name => test_app.name,
                               :space_guid => test_app.space.guid,
                               :metadata => droplet_exited_payload
    end

    example "List App Update Events" do
      app_event_repository.record_app_update(test_app, test_app.space, test_user, test_user_email, app_request)

      client.get "/v2/events?q=type:audit.app.update", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "user",
                               :actor => test_user.guid,
                               :actor_name => test_user_email,
                               :actee_type => "app",
                               :actee => test_app.guid,
                               :actee_name => test_app.name,
                               :space_guid => test_app.space.guid,
                               :metadata => {
                                 "request" => expected_app_request,
                               }
    end

    example "List App Delete Events" do
      app_event_repository.record_app_delete_request(test_app, test_app.space, test_user, test_user_email, false)

      client.get "/v2/events?q=type:audit.app.delete-request", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "user",
                               :actor => test_user.guid,
                               :actor_name => test_user_email,
                               :actee_type => "app",
                               :actee => test_app.guid,
                               :actee_name => test_app.name,
                               :space_guid => test_app.space.guid,
                               :metadata => { "request" => { "recursive" => false } }
    end

    example "List events associated with an App since January 1, 2014" do
      app_event_repository.record_app_create(test_app, test_app.space, test_user, test_user_email, app_request)
      app_event_repository.record_app_update(test_app, test_app.space, test_user, test_user_email, app_request)
      app_event_repository.record_app_delete_request(test_app, test_app.space, test_user, test_user_email, false)

      client.get "/v2/events?q=actee:#{test_app.guid}&q=#{CGI.escape('timestamp>2014-01-01 00:00:00-04:00')}", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "user",
                               :actor => test_user.guid,
                               :actor_name => test_user_email,
                               :actee_type => "app",
                               :actee => test_app.guid,
                               :actee_name => test_app.name,
                               :space_guid => test_app.space.guid,
                               :metadata => { "request" => expected_app_request }
    end

    example "List Space Create Events" do
      space_event_repository.record_space_create(test_space, test_user, test_user_email, space_request)

      client.get "/v2/events?q=type:audit.space.create", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "user",
                               :actor => test_user.guid,
                               :actor_name => test_user_email,
                               :actee_type => "space",
                               :actee => test_space.guid,
                               :actee_name => test_space.name,
                               :space_guid => test_space.guid,
                               :metadata => { "request" => space_request }

    end

    example "List Space Update Events" do
      space_event_repository.record_space_update(test_space, test_user, test_user_email, space_request)

      client.get "/v2/events?q=type:audit.space.update", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "user",
                               :actor => test_user.guid,
                               :actor_name => test_user_email,
                               :actee => test_space.guid,
                               :actee_type => "space",
                               :actee_name => test_space.name,
                               :space_guid => test_space.guid,
                               :metadata => { "request" => space_request }
    end

    example "List Space Delete Events" do
      space_event_repository.record_space_delete_request(test_space, test_user, test_user_email, true)

      client.get "/v2/events?q=type:audit.space.delete-request", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "user",
                               :actor => test_user.guid,
                               :actor_name => test_user_email,
                               :actee_type => "space",
                               :actee => test_space.guid,
                               :actee_name => test_space.name,
                               :space_guid => test_space.guid,
                               :metadata => { "request" => { "recursive" => true } }
    end

    example "List Service Create Events" do
      values = test_service.values
      values.delete(:id)
      new_service = VCAP::CloudController::Service.new(values)
      metadata = service_event_repository.metadata_for_modified_service(new_service)
      service_event_repository.create_service_event('audit.service.create', new_service, metadata)

      client.get "/v2/events?q=type:audit.service.create", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "user",
                               :actor => test_user.guid,
                               :actor_name => test_user_email,
                               :actee_type => "service",
                               :actee => new_service.guid,
                               :actee_name => new_service.label,
                               :space_guid => '',
                               :metadata => metadata.stringify_keys

    end

    example "List Service Update Events" do
      test_service.label = 'new label'
      metadata = service_event_repository.metadata_for_modified_service(test_service)
      service_event_repository.create_service_event('audit.service.update', test_service, metadata)

      client.get "/v2/events?q=type:audit.service.update", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "user",
                               :actor => test_user.guid,
                               :actor_name => test_user_email,
                               :actee_type => "service",
                               :actee => test_service.guid,
                               :actee_name => test_service.label,
                               :space_guid => '',
                               :metadata => {'entity' => {'label' => 'new label'}}
    end

    example "List Service Delete Events" do
      service_event_repository.create_service_event('audit.service.delete', test_service, {})

      client.get "/v2/events?q=type:audit.service.delete", {}, headers
      expect(status).to eq(200)
      standard_entity_response parsed_response["resources"][0], :event,
                               :actor_type => "user",
                               :actor => test_user.guid,
                               :actor_name => test_user_email,
                               :actee_type => "service",
                               :actee => test_service.guid,
                               :actee_name => test_service.label,
                               :space_guid => '',
                               :metadata => {}
    end
  end
end
