-- One row per enrolled learner x live competency criterion (an assessment, i.e. a
-- subsection, assessed for one competency). An assessment that assesses several
-- competencies has one row per competency.
--
-- Two sources, joined per learner and subsection:
-- - criterion_status comes from openedx-core (criterion status sink): Met when core
-- judged a grade of the learner's against the criterion's rule and it passed,
-- Below rule when it judged and it failed. Not judged when the learner has a grade
-- but core has no status (a grade written before the criterion existed), Not
-- attempted when there is neither.
-- Core only raises a status, so Met stays even if the grade drops later.
-- - best_grade / latest_grade come from the xAPI subsection grade statements: the
-- highest and the current grade. Null when the learner has no grade.
-- The rule (rule_label, rule_value) is the criterion's current effective rule.
with
    criteria as (
        select
            id as criterion_id, tag_id, object_id, course_key, rule_label, rule_value
        from
            {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_most_recent_competency_criteria final
        where archived = 0
    ),
    competencies as (
        select
            id as tag_id,
            value as competency,
            arrayStringConcat(
                arrayDistinct(
                    arrayPushBack(JSONExtract(lineage, 'Array(String)'), value)
                ),
                ' > '
            ) as competency_path
        from {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_most_recent_tags final
        where id in (select tag_id from criteria)
    ),
    assessments as (
        select block_id as object_id, block_name as assessment
        from {{ DBT_PROFILE_TARGET_DATABASE }}.dim_course_blocks
        where
            block_type = 'subsection'
            and block_id in (select object_id from criteria)
    ),
    learners as (
        -- Enrollments come from the event sink, not from xAPI: a learner who
        -- enrolled before xAPI collection started has no registered event.
        select org, course_key, actor_id
        from {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_most_recent_course_enrollment
        where is_active and course_key in (select course_key from criteria)
    ),
    statuses as (
        select actor_id, criterion_id, status_id, modified
        from
            {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_learner_most_recent_criterion_status final
    ),
    grades as (
        select
            actor_id,
            subsection_block_id as object_id,
            grade_writes,
            best_grade,
            latest_grade,
            first_graded_at
        from {{ DBT_PROFILE_TARGET_DATABASE }}.dim_learner_subsection_grades
        where subsection_block_id in (select object_id from criteria)
    ),
    course_statuses as (
        select actor_id, tag_id, course_key, status_id
        from
            {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_learner_most_recent_competency_course_status final
    )

select
    l.org as org,
    c.course_key as course_key,
    names.course_name as course_name,
    c.criterion_id as criterion_id,
    c.tag_id as tag_id,
    comp.competency as competency,
    comp.competency_path as competency_path,
    c.object_id as object_id,
    a.assessment as assessment,
    c.rule_label as rule_label,
    c.rule_value as rule_value,
    concat(a.assessment, ' · ', comp.competency, ' (', c.rule_label, ')') as gradebook_column,
    l.actor_id as actor_id,
    g.grade_writes > 0 as has_grade,
    if(has_grade, g.best_grade, null) as best_grade,
    if(has_grade, g.latest_grade, null) as latest_grade,
    if(has_grade, g.first_graded_at, null) as first_graded_at,
    if(has_grade, least(floor(g.best_grade * 10) * 10, 100), null) as best_grade_bucket,
    multiIf(
        s.status_id = 30,
        'Met',
        s.status_id = 10,
        'Below rule',
        has_grade,
        'Not judged',
        'Not attempted'
    ) as criterion_status,
    criterion_status != 'Not attempted' as attempted,
    criterion_status = 'Met' as met,
    multiIf(
        cs.status_id = 30,
        'Demonstrated',
        cs.status_id = 20,
        'Partially Attempted',
        cs.status_id = 10,
        'Not Demonstrated',
        'Available'
    ) as status,
    users.name as name,
    users.username as username,
    users.email as email
from criteria as c
inner join learners as l on l.course_key = c.course_key
inner join competencies as comp on comp.tag_id = c.tag_id
left join assessments as a on a.object_id = c.object_id
left join
    statuses as s on s.actor_id = l.actor_id and s.criterion_id = c.criterion_id
left join grades as g on g.actor_id = l.actor_id and g.object_id = c.object_id
left join
    course_statuses as cs
    on cs.actor_id = l.actor_id
    and cs.tag_id = c.tag_id
    and cs.course_key = c.course_key
left join
    {{ ASPECTS_EVENT_SINK_DATABASE }}.dim_course_names as names
    on names.course_key = c.course_key
left join
    {{ DBT_PROFILE_TARGET_DATABASE }}.dim_user_pii as users
    on l.actor_id = toString(users.external_user_id)
