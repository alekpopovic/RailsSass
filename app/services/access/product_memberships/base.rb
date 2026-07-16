class Access::ProductMemberships::Base
  private
    def with_locked_organization
      organization = Current.organization
      raise ActiveRecord::RecordNotFound, "organization not found" unless active_current_organization?(organization)

      Organization.transaction do
        organization.lock!
        raise ActiveRecord::RecordNotFound, "organization not found" unless active_current_organization?(organization)

        yield organization
      end
    end

    def locked_product_membership!(organization, product_membership_id)
      organization.product_memberships.lock.find(product_membership_id)
    end

    def locked_active_organization_membership!(organization, organization_membership_id)
      membership = organization.organization_memberships.lock.find(organization_membership_id)
      invalid_record!(membership, "organization membership must be active") unless membership.active?
      membership
    end

    def locked_active_product!(product_id)
      Product.where(active: true).lock.find(product_id)
    end

    def transition!(organization, product_membership, status:)
      affected_rows = organization.product_memberships
        .where(id: product_membership.id)
        .update_all(status: status, updated_at: Time.current)
      raise ActiveRecord::RecordNotFound, "product membership not found" unless affected_rows == 1

      organization.product_memberships.find(product_membership.id)
    end

    def invalid_record!(record, message)
      record.errors.add(:base, message)
      raise ActiveRecord::RecordInvalid, record
    end

    def active_current_organization?(organization)
      organization&.persisted? && organization.active? && Current.organization&.id == organization.id
    end
end
