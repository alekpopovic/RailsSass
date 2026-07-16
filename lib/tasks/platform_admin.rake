namespace :platform_admin do
  desc "Promote a verified, enabled user to platform administrator"
  task :promote, [ :email ] => :environment do |_task, arguments|
    email_address = User.normalize_email(arguments[:email])
    abort "Email is required." if email_address.blank?

    User.transaction do
      user = User.lock.find_by(email_address: email_address)
      abort "User was not found." unless user
      abort "User email must be verified." unless user.email_verified?
      abort "Disabled users cannot be platform administrators." if user.disabled?

      user.update!(system_role: :platform_admin) unless user.platform_admin?
    end

    puts "Platform administrator access granted."
  end
end
