# frozen_string_literal: true
class Zendesk2::GetUserMemberships
  include Zendesk2::Request

  request_method :get
  request_path { |r| "/users/#{r.user_id}/organization_memberships.json" }

  page_params!

  def user_id
    params.fetch('membership').fetch('user_id').to_i
  end

  def mock
    page(data[:memberships].values.select { |m| m['user_id'] == user_id }, root: 'organization_memberships')
  end
end
