class UserMailer < ApplicationMailer
  def password_reset(user)
    @user = user
    @reset_url = edit_password_url(token: user.password_reset_token)

    mail to: user.email_address, subject: "Reset your password"
  end

  def email_verification(user)
    @user = user
    @verification_url = edit_email_verification_url(token: user.email_verification_token)

    mail to: user.email_address, subject: "Verify your email address"
  end
end
