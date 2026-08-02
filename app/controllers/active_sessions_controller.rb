class ActiveSessionsController < ApplicationController
  after_action :verify_authorized
  after_action :verify_policy_scoped, only: :index

  def index
    authorize Session, :index?
    @sessions = policy_scope(Current.user.sessions.active).order(created_at: :desc)
  end

  def destroy
    session_record = Current.user.sessions.find(params[:id])
    authorize session_record, :destroy?

    if session_record == Current.session
      terminate_session
      redirect_to new_session_path, status: :see_other, notice: "That session has been signed out."
    else
      session_record.destroy!
      redirect_to active_sessions_path, status: :see_other, notice: "That session has been signed out."
    end
  end
end
