# frozen_string_literal: true

module ErrorSignal
  # Who hit the error: the alert's User field and the people count.
  #
  # Taken, in order, from the context the app passed (`user_id`, or a `user`
  # record), from the controller's `current_user` (Devise and most auth
  # gems) and from `Current.user` (the Rails 8 authentication generator).
  # Only the id leaves the app, as "User#42": never a name or an e-mail.
  # ERROR_SIGNAL_USER=false turns all of it off.
  module Person
    Found = Struct.new(:id, :label, keyword_init: true)

    CONTEXT_KEYS = %w[user_id user].freeze

    module_function

    # A Found, or nil when nobody is known (or ERROR_SIGNAL_USER=false).
    # Never raises: an auth lookup that fails (the database the error is
    # about, say) just leaves the user out.
    def of(context)
      return nil unless Config.user?

      from_context(context) || from_record(current_user(context[:controller])) || from_record(current_attribute)
    rescue StandardError
      nil
    end

    def from_context(context)
      id = context[:user_id] || context["user_id"]
      return Found.new(id: id.to_s, label: id.to_s) if id.present?

      user = context[:user] || context["user"]
      return from_record(user) if user.respond_to?(:id)

      Found.new(id: user.to_s, label: user.to_s) if (user.is_a?(String) || user.is_a?(Numeric)) && user.to_s.present?
    end

    # Counted by the id alone, so the same person in a request
    # (current_user) and in a job (user_id: 42) is one person.
    def from_record(user)
      return nil unless user.respond_to?(:id) && user.id.present?

      Found.new(id: user.id.to_s, label: "#{user.class.name}##{user.id}")
    end

    def current_user(controller)
      return nil unless controller.respond_to?(:current_user, true)

      controller.send(:current_user)
    end

    def current_attribute
      return nil unless defined?(::Current) && ::Current.respond_to?(:user)

      ::Current.user
    end
  end
end
