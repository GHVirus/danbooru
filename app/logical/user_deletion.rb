# frozen_string_literal: true

# Delete a user's account. Deleting an account really just deactivates the
# account, it doesn't fully delete the user from the database. It wipes their
# username, password, account settings, favorites, and saved searches, and logs
# the deletion.
class UserDeletion
  include ActiveModel::Validations

  attr_reader :user, :deleter, :password, :request

  validate :validate_deletion

  # Initialize a user deletion.
  # @param user [User] the user to delete
  # @param user [User] the user performing the deletion
  # @param password [String] the user's password (for confirmation)
  # @param request the HTTP request (for logging the deletion in the user event log)
  def initialize(user:, deleter: user, password: nil, request: nil)
    @user = user
    @deleter = deleter
    @password = password
    @request = request
  end

  # Delete the account, if the deletion is allowed.
  # @return [Boolean] if the deletion failed
  # @return [User] if the deletion succeeded
  def delete!
    return false if invalid?

    clear_user_settings
    remove_favorites
    clear_saved_searches
    rename
    reset_password
    create_mod_action
    create_user_event
    user
  end

  private

  def create_mod_action
    ModAction.log("deleted user ##{user.id}", :user_delete, deleter)
  end

  def create_user_event
    UserEvent.create_from_request!(user, :user_deletion, request) if request.present?
  end

  def clear_saved_searches
    SavedSearch.where(user_id: user.id).destroy_all
  end

  def clear_user_settings
    user.email_address = nil
    user.last_logged_in_at = nil
    user.last_forum_read_at = nil
    user.favorite_tags = ""
    user.blacklisted_tags = ""
    user.show_deleted_children = false
    user.time_zone = "Eastern Time (US & Canada)"
    user.save!
  end

  def reset_password
    user.update!(password: SecureRandom.hex(16))
  end

  def remove_favorites
    DeleteFavoritesJob.perform_later(user)
  end

  def rename
    name = "user_#{user.id}"
    name += "~" while User.exists?(name: name)

    request = UserNameChangeRequest.new(user: user, desired_name: name, original_name: user.name)
    request.save!(validate: false) # XXX don't validate so that the 1 name change per week rule doesn't interfere
  end

  def validate_deletion
    if user == deleter
      if !user.authenticate_password(password)
        errors.add(:base, "Password is incorrect")
      end

      if user.is_admin?
        errors.add(:base, "Admins cannot delete their account")
      end

      if user.is_banned?
        errors.add(:base, "You cannot delete your account if you are banned")
      end
    else
      if !deleter.is_owner?
        errors.add(:base, "You cannot delete an account belonging to another user")
      end

      if user.is_gold?
        errors.add(:base, "You cannot delete a privileged account")
      end

      if user.created_at.before?(6.months.ago)
        errors.add(:base, "You cannot delete a recent account")
      end
    end
  end
end
