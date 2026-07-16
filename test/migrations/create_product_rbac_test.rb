require "test_helper"
require_relative "../support/product_rbac_test_helper"

class CreateProductRbacTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  test "tables install required columns checks and unique indexes" do
    assert_required_columns(
      ProductPermission,
      %w[product_id key name description created_at updated_at]
    )
    assert_required_columns(
      ProductRole,
      %w[product_id key name system active created_at updated_at]
    )
    assert_required_columns(
      ProductRolePermission,
      %w[product_id product_role_id product_permission_id created_at updated_at]
    )
    assert_required_columns(
      ProductMembership,
      %w[
        organization_id organization_membership_id organization_membership_status
        product_id status created_at updated_at
      ]
    )
    assert_required_columns(
      ProductMembershipRole,
      %w[
        organization_id product_id product_membership_id product_role_id
        created_at updated_at
      ]
    )
    assert ProductRole.columns_hash.fetch("organization_id").null

    assert_constraint_names ProductPermission, %w[
      product_permissions_key_format
      product_permissions_name_normalized
      product_permissions_description_normalized
    ]
    assert_constraint_names ProductRole, %w[
      product_roles_key_format
      product_roles_name_normalized
      product_roles_system_scope_consistent
    ]
    assert_constraint_names ProductMembership, %w[
      product_memberships_parent_membership_active
      product_memberships_status_allowed
    ]

    assert_predicate index_for(
      ProductPermission,
      "index_product_permissions_on_product_id_and_key"
    ), :unique
    assert_predicate index_for(
      ProductRole,
      "index_product_roles_on_system_product_and_key"
    ), :unique
    assert_match(/organization_id IS NULL/i, index_for(
      ProductRole,
      "index_product_roles_on_system_product_and_key"
    ).where)
    assert_predicate index_for(
      ProductRole,
      "index_product_roles_on_organization_product_and_key"
    ), :unique
    assert_predicate index_for(
      ProductMembership,
      "index_product_memberships_on_membership_and_product"
    ), :unique
    assert_predicate index_for(
      ProductMembershipRole,
      "index_product_membership_roles_on_membership_and_role"
    ), :unique
  end

  test "composite foreign keys enforce role permission product identity" do
    product = create_test_product
    role = create_test_product_role(product: product)
    permission = create_test_product_permission(product: product)
    mapping = create_test_product_role_permission(
      product_role: role,
      product_permission: permission
    )

    assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      ProductRolePermission.insert_all!([ raw_role_permission_attributes(
        product_role: role,
        product_permission: permission
      ) ])
    end

    foreign_permission = create_test_product_permission(product: create_test_product)
    assert_database_error(ActiveRecord::InvalidForeignKey, PG::ForeignKeyViolation) do
      ProductRolePermission.insert_all!([ raw_role_permission_attributes(
        product_role: role,
        product_permission: foreign_permission,
        product_id: product.id
      ) ])
    end

    assert ProductRolePermission.exists?(mapping.id)
    role_foreign_keys = ProductRolePermission.connection.foreign_keys(:product_role_permissions)
    assert role_foreign_keys.any? { |foreign_key|
      foreign_key.to_table == "product_roles" &&
        foreign_key.column == %w[product_role_id product_id]
    }
    assert role_foreign_keys.any? { |foreign_key|
      foreign_key.to_table == "product_permissions" &&
        foreign_key.column == %w[product_permission_id product_id]
    }
  end

  test "database enforces stable key scope and system role ownership" do
    product = create_test_product
    permission = create_test_product_permission(product: product, key: "reports.view")
    role = create_test_product_role(product: product, key: "viewer")

    assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      ProductPermission.insert_all!([ raw_permission_attributes(
        product: product,
        key: permission.key
      ) ])
    end
    assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      ProductRole.insert_all!([ raw_role_attributes(
        product: product,
        key: role.key
      ) ])
    end
    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      ProductRole.insert_all!([ raw_role_attributes(
        product: product,
        key: "invalid_scope",
        system: false,
        organization_id: nil
      ) ])
    end
    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      ProductPermission.insert_all!([ raw_permission_attributes(
        product: create_test_product,
        key: "invalid_permission"
      ) ])
    end
    %w[reports_.view reports__draft.view reports.view_].each do |malformed_key|
      assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
        ProductPermission.insert_all!([ raw_permission_attributes(
          product: create_test_product,
          key: malformed_key
        ) ])
      end
    end
  end

  test "active parent composite foreign key prevents cross-tenant or suspended assignments" do
    owner = create_test_user(email_address: "rbac-db-owner@example.test")
    organization, = create_test_organization_with_owner(
      owner: owner,
      name: "RBAC Database Organization",
      slug: "rbac-database-organization"
    )
    member = create_test_user(email_address: "rbac-db-member@example.test")
    organization_membership = create_test_membership(
      organization: organization,
      user: member,
      role: :member
    )
    other_owner = create_test_user(email_address: "rbac-db-other-owner@example.test")
    other_organization, = create_test_organization_with_owner(
      owner: other_owner,
      name: "Other RBAC Database Organization",
      slug: "other-rbac-database-organization"
    )
    product = create_test_product
    product_membership = create_test_product_membership(
      organization_membership: organization_membership,
      product: product
    )

    assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      ProductMembership.insert_all!([ raw_product_membership_attributes(
        organization: organization,
        organization_membership: organization_membership,
        product: product
      ) ])
    end
    assert_database_error(ActiveRecord::InvalidForeignKey, PG::ForeignKeyViolation) do
      ProductMembership.insert_all!([ raw_product_membership_attributes(
        organization: other_organization,
        organization_membership: organization_membership,
        product: create_test_product
      ) ])
    end

    suspended_user = create_test_user(email_address: "rbac-db-suspended@example.test")
    suspended_parent = create_test_membership(
      organization: organization,
      user: suspended_user,
      role: :member,
      status: :suspended
    )
    assert_database_error(ActiveRecord::InvalidForeignKey, PG::ForeignKeyViolation) do
      ProductMembership.insert_all!([ raw_product_membership_attributes(
        organization: organization,
        organization_membership: suspended_parent,
        product: create_test_product
      ) ])
    end
    assert_database_error(ActiveRecord::InvalidForeignKey, PG::ForeignKeyViolation) do
      organization.organization_memberships.where(id: organization_membership.id)
        .update_all(status: "suspended", updated_at: Time.current)
    end

    assert ProductMembership.exists?(product_membership.id)
    assert_predicate organization_membership.reload, :active?
  end

  test "membership role constraints reject cross-product foreign-tenant inactive and duplicate roles" do
    owner = create_test_user(email_address: "rbac-role-db-owner@example.test")
    organization, organization_membership = create_test_organization_with_owner(
      owner: owner,
      name: "RBAC Role Database Organization",
      slug: "rbac-role-database-organization"
    )
    product = create_test_product
    product_membership = create_test_product_membership(
      organization_membership: organization_membership,
      product: product
    )
    system_role = create_test_product_role(product: product)
    assignment = create_test_product_membership_role(
      product_membership: product_membership,
      product_role: system_role
    )

    assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      ProductMembershipRole.insert_all!([ raw_membership_role_attributes(
        product_membership: product_membership,
        product_role: system_role
      ) ])
    end
    assert_database_error(ActiveRecord::InvalidForeignKey, PG::ForeignKeyViolation) do
      ProductMembershipRole.insert_all!([ raw_membership_role_attributes(
        product_membership: product_membership,
        product_role: create_test_product_role(product: create_test_product),
        product_id: product.id
      ) ])
    end

    foreign_owner = create_test_user(email_address: "rbac-role-db-foreign@example.test")
    foreign_organization, = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign RBAC Role Database Organization",
      slug: "foreign-rbac-role-database-organization"
    )
    foreign_role = create_test_product_role(
      product: product,
      organization: foreign_organization
    )
    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      ProductMembershipRole.insert_all!([ raw_membership_role_attributes(
        product_membership: product_membership,
        product_role: foreign_role
      ) ])
    end

    inactive_role = create_test_product_role(product: product, active: false)
    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      ProductMembershipRole.insert_all!([ raw_membership_role_attributes(
        product_membership: product_membership,
        product_role: inactive_role
      ) ])
    end

    assert ProductMembershipRole.exists?(assignment.id)
  end

  test "referenced roles are delete restricted and role identity is database immutable" do
    product = create_test_product
    role = create_test_product_role(product: product)
    create_test_product_role_permission(
      product_role: role,
      product_permission: create_test_product_permission(product: product)
    )

    assert_database_error(ActiveRecord::InvalidForeignKey, PG::ForeignKeyViolation) do
      ProductRole.where(id: role.id).delete_all
    end
    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      ProductRole.where(id: role.id).update_all(key: "changed_identity")
    end

    assert_equal 1, ProductRole.where(id: role.id).update_all(active: false)
    assert_not role.reload.active?
  end

  test "membership role joins cascade only when their product membership is removed" do
    owner = create_test_user(email_address: "rbac-cascade-owner@example.test")
    _organization, organization_membership = create_test_organization_with_owner(
      owner: owner,
      name: "RBAC Cascade Organization",
      slug: "rbac-cascade-organization"
    )
    product = create_test_product
    membership = create_test_product_membership(
      organization_membership: organization_membership,
      product: product
    )
    assignment = create_test_product_membership_role(
      product_membership: membership,
      product_role: create_test_product_role(product: product)
    )
    membership_foreign_key = ProductMembershipRole.connection
      .foreign_keys(:product_membership_roles)
      .find { |foreign_key| foreign_key.to_table == "product_memberships" }

    assert_equal :cascade, membership_foreign_key.on_delete
    assert_equal %w[product_membership_id organization_id product_id],
      membership_foreign_key.column

    ProductMembership.where(id: membership.id).delete_all
    assert_not ProductMembershipRole.exists?(assignment.id)
  end

  private
    def assert_required_columns(model, column_names)
      columns = model.columns.index_by(&:name)
      column_names.each do |column_name|
        assert_not columns.fetch(column_name).null,
          "expected #{model.table_name}.#{column_name} to be NOT NULL"
      end
    end

    def assert_constraint_names(model, expected_names)
      names = model.connection.check_constraints(model.table_name).map(&:name)
      expected_names.each { |name| assert_includes names, name }
    end

    def index_for(model, name)
      model.connection.indexes(model.table_name).index_by(&:name).fetch(name)
    end

    def assert_database_error(exception_class, cause_class, &block)
      error = assert_raises(exception_class) do
        ApplicationRecord.transaction(requires_new: true, &block)
      end
      assert_kind_of cause_class, error.cause
    end

    def raw_permission_attributes(product:, key:, **overrides)
      {
        product_id: product.id,
        key: key,
        name: "Raw permission",
        description: "Synthetic raw permission.",
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end

    def raw_role_attributes(product:, key:, **overrides)
      {
        product_id: product.id,
        organization_id: nil,
        key: key,
        name: "Raw role",
        system: true,
        active: true,
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end

    def raw_role_permission_attributes(product_role:, product_permission:, **overrides)
      {
        product_id: product_role.product_id,
        product_role_id: product_role.id,
        product_permission_id: product_permission.id,
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end

    def raw_product_membership_attributes(
      organization:,
      organization_membership:,
      product:,
      **overrides
    )
      {
        organization_id: organization.id,
        organization_membership_id: organization_membership.id,
        organization_membership_status: "active",
        product_id: product.id,
        status: "active",
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end

    def raw_membership_role_attributes(product_membership:, product_role:, **overrides)
      {
        organization_id: product_membership.organization_id,
        product_id: product_membership.product_id,
        product_membership_id: product_membership.id,
        product_role_id: product_role.id,
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end
end
