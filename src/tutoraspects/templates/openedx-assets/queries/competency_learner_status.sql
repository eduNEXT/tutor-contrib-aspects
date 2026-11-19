-- One row per learner x competency x course the learner is enrolled in that
-- assesses the competency. Learners with a status but no such enrollment get one
-- row with an empty course.
--
-- Aspects never derives a status that openedx-core doesn't store:
-- - competency_status is the learner's competency-level status from core:
-- Demonstrated, Partially Attempted or Available (no row). Core never stores
-- AttemptedNotDemonstrated per competency, because the learner can still
-- demonstrate it in another course.
-- - course_status is the learner's status in that row's course, from the
-- course-level criteria group: all four states, Not Demonstrated included.
-- - status is what the charts show: course_status when the Course filter selects
-- exactly one course, competency_status otherwise. So Not Demonstrated appears
-- only once the dashboard is scoped to one course.
--
-- Count learners with COUNT(DISTINCT actor_id): the competency status repeats on
-- every course row, and a Course filter keeps the learners enrolled in that course.
with
    competency_taxonomies as (
        select id as taxonomy_id
        from {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_most_recent_taxonomies final
        where taxonomy_type = 'competency'
    ),
    competencies as (
        select
            id as tag_id,
            taxonomy as taxonomy_id,
            value as competency,
            -- The platform's lineage ends with the tag itself; make sure it does.
            arrayDistinct(
                arrayPushBack(JSONExtract(lineage, 'Array(String)'), value)
            ) as lineage_values,
            arrayStringConcat(lineage_values, ' > ') as competency_path,
            -- Leaf competencies have no sub-competencies; parents roll up from them.
            if(
                id in (
                    select parent
                    from {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_most_recent_tags
                    where parent != 0
                ),
                'Parent',
                'Leaf'
            ) as competency_level
        from {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_most_recent_tags
        where taxonomy in (select taxonomy_id from competency_taxonomies)
    ),
    competency_ancestors as (
        -- Each competency paired with itself and every ancestor, so content
        -- tagged with a child also counts for its parents.
        select c.tag_id as tag_id, ancestor.tag_id as ancestor_tag_id
        from
            (
                select tag_id, taxonomy_id, ancestor_value
                from competencies array
                join lineage_values as ancestor_value
            ) as c
        inner join
            competencies as ancestor
            on ancestor.taxonomy_id = c.taxonomy_id
            and ancestor.competency = c.ancestor_value
    ),
    tagged_content as (
        -- Content tagged with a competency, or with any of its descendants.
        select distinct object_tag.object_id as object_id, a.ancestor_tag_id as tag_id
        from {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_most_recent_object_tags as object_tag
        inner join
            competencies as c
            on c.taxonomy_id = object_tag.taxonomy
            and c.competency = object_tag._value
        inner join competency_ancestors as a on a.tag_id = c.tag_id
    ),
    competency_courses as (
        -- The course key of a tagged course or block. Also accepts block ids that
        -- embed the whole course key (block-v1:course-v1:Org+Course+Run+type@...),
        -- as xapi-db-load's fake blocks do.
        select distinct
            tag_id,
            if(
                startsWith(object_id, 'course-v1:'),
                object_id,
                concat(
                    'course-v1:',
                    extract(
                        object_id,
                        '^block-v1:(?:course-v1:)?([^+]+[+][^+]+[+][^+]+)[+]type@'
                    )
                )
            ) as course_key
        from tagged_content
        where
            startsWith(object_id, 'course-v1:')
            or match(
                object_id, '^block-v1:(?:course-v1:)?[^+]+[+][^+]+[+][^+]+[+]type@'
            )
    ),
    learner_competency_courses as (
        select
            enrollment.org as org,
            cc.course_key as course_key,
            enrollment.actor_id as actor_id,
            cc.tag_id as tag_id
        from {{ DBT_PROFILE_TARGET_DATABASE }}.dim_most_recent_enrollment as enrollment
        inner join
            competency_courses as cc on cc.course_key = enrollment.course_key::String
        where enrollment.enrollment_status = 'registered'
    ),
    statuses as (
        -- Latest status per learner x competency. created is the first status.
        -- openedx-core only raises statuses today, so on a Demonstrated row
        -- modified is the mastery date.
        select actor_id, tag_id, status_id, created, modified
        from
            {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_learner_most_recent_competency_status final
    ),
    course_statuses as (
        -- Latest status per learner x competency x course run.
        select actor_id, tag_id, course_key, status_id
        from
            {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_learner_most_recent_competency_course_status final
    ),
    learner_competencies as (
        select org, course_key, actor_id, tag_id
        from learner_competency_courses
        union distinct
        select '' as org, '' as course_key, actor_id, tag_id
        from statuses
        where
            (actor_id, tag_id)
            not in (select actor_id, tag_id from learner_competency_courses)
    ),
    first_activity as (
        -- First xAPI event on content tagged with the competency: the tagged
        -- block itself, or anything inside a tagged section or subsection.
        select
            events.actor_id as actor_id,
            tagged_content.tag_id as tag_id,
            min(events.emission_time) as first_activity_at
        from
            (
                -- The block id, without any trailing path such as /answer.
                select
                    actor_id,
                    extract(object_id, '/xblock/([^/]+)') as block_id,
                    emission_time
                from {{ ASPECTS_XAPI_DATABASE }}.xapi_events_all_parsed
                where
                    position(object_id, '/xblock/') > 0
                    and actor_id in (select actor_id from learner_competencies)
            ) as events
        inner join
            (
                select
                    block_id,
                    arrayJoin(
                        [block_id, subsection_block_id, section_block_id]
                    ) as container_id
                from {{ DBT_PROFILE_TARGET_DATABASE }}.dim_course_blocks
            ) as blocks
            on blocks.block_id = events.block_id
        inner join tagged_content on tagged_content.object_id = blocks.container_id
        group by events.actor_id, tagged_content.tag_id
    ),
    learner_rows as (
        select
            lc.org as org,
            lc.course_key as course_key,
            lc.actor_id as actor_id,
            lc.tag_id as tag_id,
            s.status_id as competency_status_id,
            s.created as created,
            s.modified as modified,
            cs.status_id as course_status_id
        from learner_competencies as lc
        left join statuses as s on s.actor_id = lc.actor_id and s.tag_id = lc.tag_id
        left join
            course_statuses as cs
            on cs.actor_id = lc.actor_id
            and cs.tag_id = lc.tag_id
            and cs.course_key = lc.course_key
    )

select
    lr.org as org,
    lr.course_key as course_key,
    names.course_name as course_name,
    lr.actor_id as actor_id,
    lr.tag_id as tag_id,
    c.competency as competency,
    c.competency_path as competency_path,
    c.competency_level as competency_level,
    c.taxonomy_id as taxonomy_id,
    multiIf(
        lr.competency_status_id = 30,
        'Demonstrated',
        lr.competency_status_id = 20,
        'Partially Attempted',
        'Available'
    ) as competency_status,
    multiIf(
        lr.course_status_id = 30,
        'Demonstrated',
        lr.course_status_id = 20,
        'Partially Attempted',
        lr.course_status_id = 10,
        'Not Demonstrated',
        'Available'
    ) as course_status,
    {% raw -%}
    {% if filter_values("course_name") | length == 1 %} course_status
    {% else %} competency_status
    {% endif %}
    {%- endraw %} as status,
    if(lr.competency_status_id = 0, null, lr.created) as first_status_at,
    if(lr.competency_status_id = 30, lr.modified, null) as mastered_at,
    multiIf(
        fa.first_activity_at = toDateTime64(0, 6),
        first_status_at,
        first_status_at is null,
        fa.first_activity_at,
        least(fa.first_activity_at, first_status_at)
    ) as first_attempt_at,
    dateDiff('second', first_attempt_at, mastered_at) as time_to_mastery_seconds,
    users.name as name,
    users.username as username,
    users.email as email
from learner_rows as lr
inner join competencies as c on c.tag_id = lr.tag_id
left join first_activity as fa on fa.actor_id = lr.actor_id and fa.tag_id = lr.tag_id
left join
    {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_course_names as names
    on names.course_key = lr.course_key
left join
    {{ DBT_PROFILE_TARGET_DATABASE }}.dim_user_pii as users
    on lr.actor_id = toString(users.external_user_id)
