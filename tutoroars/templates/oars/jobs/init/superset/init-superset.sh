#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Modified from original:
#
# https://github.com/apache/superset/blob/969c963/docker/docker-init.sh

set -e

#
# Always install local overrides first
#
/usr/bin/env bash /app/docker/docker-bootstrap.sh

STEP_CNT=3

echo_step() {
cat <<EOF

######################################################################


Init Step ${1}/${STEP_CNT} [${2}] -- ${3}


######################################################################

EOF
}
# Initialize the database
echo_step "1" "Starting" "Applying DB migrations"
superset db upgrade
superset init
echo_step "1" "Complete" "Applying DB migrations"

# Create an admin user
echo_step "2" "Starting" "Setting up admin user"
superset fab create-admin \
  --username "{{ SUPERSET_ADMIN_USERNAME }}" \
  --password "{{ SUPERSET_ADMIN_PASSWORD }}" \
  --firstname Superset \
  --lastname Admin \
  --email "{{ SUPERSET_ADMIN_EMAIL }}"

# Update the password of the Admin user
# (in case it changed since the user was created)
superset fab reset-password \
  --username "{{ SUPERSET_ADMIN_USERNAME }}" \
  --password "{{ SUPERSET_ADMIN_PASSWORD }}"
echo_step "2" "Complete" "Setting up admin user"

# Create default roles and permissions
echo_step "3" "Starting" "Setting up roles and perms"
superset fab import-roles -p /app/security/roles.json
echo_step "3" "Complete" "Setting up roles and perms"

# Set up a Row-Level Security filter to enforce course-based access restrictions.
# Note: there are no cli commands or REST API endpoints to help us with this,
# so we have to pipe python code directly into the superset shell. Yuck!
superset shell <<EOF
from superset.connectors.sqla.models import (
    RowLevelSecurityFilter,
    RLSFilterRoles,
    SqlaTable,
)
from superset.utils.core import RowLevelSecurityFilterType
from superset.extensions import security_manager
from superset.migrations.shared.security_converge import Role

session = security_manager.get_session()

# Fetch the Open edX role
role_name = "{{SUPERSET_OPENEDX_ROLE_NAME}}"
openedx_role = session.query(Role).filter(Role.name == role_name).first()
assert openedx_role, "{{SUPERSET_OPENEDX_ROLE_NAME}} role doesn't exist yet?"

for (schema, table_name, group_key, clause, filter_type) in (
    (
        "{{OARS_XAPI_DATABASE}}",
        "{{OARS_XAPI_TABLE}}",
        "{{SUPERSET_ROW_LEVEL_SECURITY_XAPI_GROUP_KEY}}",
        {% raw %}
        '{{can_view_courses(current_username(), "splitByChar(\'/\', course_id)[-1]")}}',
        {% endraw %}
        RowLevelSecurityFilterType.REGULAR,
    ),
    (
        "{{OPENEDX_MYSQL_DATABASE}}",
        "{{OARS_SUPERSET_ENROLLMENTS_TABLE}}",
        "{{SUPERSET_ROW_LEVEL_SECURITY_ENROLLMENTS_GROUP_KEY}}",
        {% raw %}
        '{{can_view_courses(current_username(), "course_key")}}',
        {% endraw %}
        RowLevelSecurityFilterType.REGULAR,
    ),
):
    # Fetch the table we want to restrict access to
    table = session.query(SqlaTable).filter(
        SqlaTable.schema == schema
    ).filter(
        SqlaTable.table_name == table_name
    ).first()
    assert table, f"{schema}.{table_name} table doesn't exist yet?"
    # See if the Row Level Security Filter already exists
    rlsf = (
        session.query(
            RowLevelSecurityFilter
        ).filter(
            RLSFilterRoles.c.role_id.in_((openedx_role.id,))
        ).filter(
            RowLevelSecurityFilter.group_key == group_key
        )
    ).first()
    # If it doesn't already exist, create one
    if rlsf:
        create = False
    else:
        create = True
        rlsf = RowLevelSecurityFilter()
    # Sync the fields to our expectations
    rlsf.filter_type = filter_type
    rlsf.group_key = group_key
    rlsf.tables = [table]
    rlsf.clause = clause
    # Create if needed
    if create:
        session.add(rlsf)
        # ...and commit, so we are sure to have an rlsf.id
        session.commit()
    # Add the filter role if needed
    rls_filter_roles = (
        session.query(
            RLSFilterRoles
        ).filter(
            RLSFilterRoles.c.role_id == openedx_role.id
        ).filter(
            RLSFilterRoles.c.rls_filter_id == rlsf.id
        )
    )
    if not rls_filter_roles.count():
        session.execute(RLSFilterRoles.insert(), [
            dict(
                role_id=openedx_role.id,
                rls_filter_id=rlsf.id
            )
        ])
        session.commit()

print("Successfully create row-level security filters.")

EOF
# The blank line above EOF is critical -- don't remove it.
# And we can't have any indented blank lines for some reason, with code piped into the superset shell

apt update
apt install zip unzip

rm -rf /app/assets/superset

cd /app/assets/

python /app/pythonpath/create_assets.py

date=$(date -u +"%Y-%m-%dT%H:%M:%S.%6N+00:00") 

echo "version: 1.0.0
type: Dashboard
timestamp: '$date'" > superset/metadata.yaml

echo "\n\nCompressing superset folder\n\n"
zip -r superset.zip superset

echo "\n\nListing files in zip\n\n"
unzip -l superset.zip

echo "\n\nImporting zip file\n\n"
superset import-dashboards -p superset.zip

rm -rf /app/assets/superset
rm -rf /app/assets/superset.zip
