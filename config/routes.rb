Rails.application.routes.draw do
  resource :registration, only: %i[ new create ]
  resource :session, only: %i[ new create destroy ]
  resources :active_sessions, only: %i[ index destroy ]
  resource :password, only: %i[ new create edit update ]
  resource :email_verification, only: %i[ new create edit update ]
  resources :organizations, only: %i[ new create ]

  scope "/o/:organization_slug", as: :organization, module: :organizations do
    get "dashboard", to: "dashboard#show", as: :dashboard
    get "invitations/accept", to: "invitation_acceptances#show", as: :invitation_acceptance
    patch "invitations/accept", to: "invitation_acceptances#update"

    resources :members, only: %i[index update] do
      member do
        patch :suspend
        patch :reactivate
      end
    end
    resources :invitations, only: %i[new create] do
      member do
        post :resend
        patch :revoke
      end
    end
    get "settings", to: "settings#show", as: :settings
    get "billing", to: "billing#show", as: :billing
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "home#show"
end
