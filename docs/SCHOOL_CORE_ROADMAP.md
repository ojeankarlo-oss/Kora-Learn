# SCHOOL-CORE roadmap

**AUDIT FIRST — REUSE FIRST — IMPLEMENT ONLY THE GAP.**

KORA Learn already contains substantial academic infrastructure derived from or shared with the KORA ENEM/ETEC academic model. Do not assume SCHOOL-CORE-004 through SCHOOL-CORE-013 require full new modules. For each slice: audit existing capability; identify reusable tables, services, endpoints, UI, and tests; distinguish generic academic behavior from ENEM/ETEC-specific behavior; classify gaps; implement only verified gaps; independently test; then close the slice.

Use these statuses: **CLOSED**, **AUDIT**, **GAP IDENTIFIED**, **IMPLEMENTATION**, **QA**, **BLOCKED**, **NOT STARTED**.

## Slice status

| Slice | Scope | Status |
| --- | --- | --- |
| SC-001 | Initial school-core audit | CLOSED |
| SC-002 | Session, identity, and authority | CLOSED |
| SC-003 | Cross-tenant academic integrity | CLOSED |
| SC-004 | School configuration and teacher assignment | NOT STARTED |
| SC-005 | Academic period, school year, and history | NOT STARTED |
| SC-006 | Classes, subjects, and academic offerings | NOT STARTED |
| SC-007 | Students | NOT STARTED |
| SC-008 | Guardians and family relationships | NOT STARTED |
| SC-009 | Enrollment and academic relationships | NOT STARTED |
| SC-010 | Attendance | NOT STARTED |
| SC-011 | Assessments, authorization, and secrecy | NOT STARTED |
| SC-012 | Grades and academic results | NOT STARTED |
| SC-013 | Portals, documents, and final school workflows | NOT STARTED |
| SC-014 | Automated end-to-end school homologation | NOT STARTED |
| SC-015 | Student/payer relationship and financial completion | NOT STARTED |

Canonical completion after SC-003: `9959819af0524fc1116e6664c8466fe38d9bf362`.

## SC-014 homologation target

Use at least two independent tenants, School A and School B. Prove the complete flow: school configuration → academic period → teacher → class/subject assignment → student → guardian → enrollment → attendance → assessment → grade/result → student/family visibility → management visibility. Negative homologation must prove School A cannot read, mutate, or create relationships with School B data. Core homologation is separate from optional future product differentiation.

## Future, non-blocking: Inteligência Pedagógica de Turma

Before any KORA Learn implementation, perform a **KORA ENEM → KORA Learn Intelligence Reuse Audit** of the existing classroom and student intelligence model. Inspect class learning snapshots, individual/student snapshots, engagement and performance indicators, attention signals, teacher and coordinator/management views, authorization, tenant isolation, explainability, tests, reusable services, and UI.

AI and data assist teachers and management; they do not replace pedagogical judgment. A future KORA Learn version may combine attendance, academic performance, assessments, grades, engagement, and pedagogical evidence. This feature is not on the critical path for initial SCHOOL-CORE homologation.

## Future, non-blocking differentiators

- KORA Studio de Atividades and teacher-created gamified activities
- Diário de Evidências Pedagógicas and external activity records
- Guardian digital authorizations and configurable retention/disposal policy
- Teacher AI assistance and pedagogical dashboards

## Product priority

Every new teacher-facing feature should materially save teacher time, reduce bureaucracy, improve pedagogical intervention, or strengthen the school-family connection. If it achieves none of these, it is not a priority.
