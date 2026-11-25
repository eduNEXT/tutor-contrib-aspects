from alembic import op

revision = "0046"
down_revision = "0045"
branch_labels = None
depends_on = None
on_cluster = " ON CLUSTER '{{CLICKHOUSE_CLUSTER_NAME}}' " if "{{CLICKHOUSE_CLUSTER_NAME}}" else ""
engine = (
    "ReplicatedReplacingMergeTree"
    if "{{CLICKHOUSE_CLUSTER_NAME}}"
    else "ReplacingMergeTree"
)


def upgrade():
    # openedx-core CompetencyCriterion: one subsection (object_id) assessed for one
    # competency (tag_id). course_key is the course-level group above it. The rule is
    # the effective one (the criterion's override, else its rule profile's rule),
    # resolved at dump time; a rule profile change re-dumps its criteria.
    op.execute(
        f"""
        CREATE TABLE IF NOT EXISTS {{ ASPECTS_EVENT_SINK_DATABASE }}.competency_criterion
        {on_cluster}
        (
            id Int64 NOT NULL,
            uuid UUID NOT NULL,
            group_id Int64 NOT NULL,
            tag_id Int64 NOT NULL,
            taxonomy_id Int64 NOT NULL,
            object_id String NOT NULL,
            course_key String NOT NULL,
            rule_source LowCardinality(String) NOT NULL,
            rule_profile_id Nullable(Int64),
            rule_type LowCardinality(String) NOT NULL,
            rule_payload String NOT NULL,
            archived UInt8 NOT NULL,
            dump_id UUID NOT NULL,
            time_last_dumped String NOT NULL
        ) ENGINE {engine}
        ORDER BY (id, time_last_dumped)
        PRIMARY KEY (id, time_last_dumped);
        """
    )
    # openedx-core StudentCompetencyCriterionStatus: a learner's status on one
    # criterion, only ever raised. The criterion's competency, subsection and course
    # never change, so they are denormalized; its rule can, so it is not (join
    # competency_criterion). Keyed by the xAPI actor_id, so no PII.
    op.execute(
        f"""
        CREATE TABLE IF NOT EXISTS {{ ASPECTS_EVENT_SINK_DATABASE }}.student_competency_criterion_status
        {on_cluster}
        (
            id Int64 NOT NULL,
            actor_id String NOT NULL,
            criterion_id Int64 NOT NULL,
            tag_id Int64 NOT NULL,
            taxonomy_id Int64 NOT NULL,
            object_id String NOT NULL,
            course_key String NOT NULL,
            status_id UInt8 NOT NULL,
            status_name LowCardinality(String) NOT NULL,
            created String NOT NULL,
            modified String NOT NULL,
            dump_id UUID NOT NULL,
            time_last_dumped String NOT NULL
        ) ENGINE {engine}
        ORDER BY (id, time_last_dumped)
        PRIMARY KEY (id, time_last_dumped);
        """
    )


def downgrade():
    op.execute(
        "DROP TABLE IF EXISTS {{ ASPECTS_EVENT_SINK_DATABASE }}.student_competency_criterion_status"
        f"{on_cluster};"
    )
    op.execute(
        "DROP TABLE IF EXISTS {{ ASPECTS_EVENT_SINK_DATABASE }}.competency_criterion"
        f"{on_cluster};"
    )
