Rails.application.routes.draw do
  resource :registration, only: %i[ new create ]
  resource :session, only: %i[ new create destroy ]
  resources :active_sessions, only: %i[ index destroy ]
  resource :password, only: %i[ new create edit update ]
  resource :email_verification, only: %i[ new create edit update ]
  resource :profile, only: %i[ show update ]
  resources :organizations, only: %i[ new create ]

  namespace :admin do
    root "products#index"

    resources :products, param: :key, except: :destroy do
      resources :features,
        controller: :product_features,
        param: :key,
        except: :destroy
    end

    resources :plans, param: :key, except: :destroy do
      resources :plan_products,
        path: "products",
        param: :product_key,
        only: %i[index show new create]
      resources :plan_prices,
        path: "prices",
        only: %i[index show new create edit update] do
          resources :provider_price_mappings,
            path: "provider-mappings",
            param: :environment,
            controller: "provider_price_mappings",
            only: %i[new create edit update]
        end
    end

    get "plans/:plan_key/products/:product_key/entitlements",
      to: "plan_feature_entitlements#index",
      as: :plan_feature_entitlements
    get "plans/:plan_key/products/:product_key/entitlements/new",
      to: "plan_feature_entitlements#new",
      as: :new_plan_feature_entitlement
    post "plans/:plan_key/products/:product_key/entitlements",
      to: "plan_feature_entitlements#create",
      as: :create_plan_feature_entitlement
    get "plans/:plan_key/products/:product_key/entitlements/:feature_key",
      to: "plan_feature_entitlements#show",
      as: :plan_feature_entitlement
    get "plans/:plan_key/products/:product_key/entitlements/:feature_key/edit",
      to: "plan_feature_entitlements#edit",
      as: :edit_plan_feature_entitlement
    patch "plans/:plan_key/products/:product_key/entitlements/:feature_key",
      to: "plan_feature_entitlements#update"
    put "plans/:plan_key/products/:product_key/entitlements/:feature_key",
      to: "plan_feature_entitlements#update"

    namespace :billing do
      resources :subscriptions, only: %i[index show]
      resources :webhook_events, only: %i[index show]
    end
  end

  scope "/o/:organization_slug", as: :organization, module: :organizations do
    get "dashboard", to: "dashboard#show", as: :dashboard
    get "products", to: "products#index", as: :products
    get "pricing", to: "pricing#index", as: :pricing

    scope "products/:product_key", as: :product do
      resources :members, controller: :product_memberships, only: %i[index create destroy] do
        member do
          patch :suspend
          patch :reactivate
          post :assign_role
          delete :unassign_role
        end
      end
    end

    scope "analytics", as: :analytics, module: :analytics do
      get "dashboard", to: "dashboard#show", as: :dashboard
      resources :reports, param: :public_id, only: %i[index new create show] do
        member do
          get :export, defaults: { format: :csv }
        end
      end
    end

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
    patch "settings", to: "settings#update"
    get "billing", to: "billing#show", as: :billing
    post "billing/checkouts", to: "billing_checkouts#create", as: :billing_checkouts
    get "billing/checkouts/pending", to: "billing_checkouts#pending", as: :billing_checkout_pending
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
