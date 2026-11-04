"""Post-apply repetition is useful evidence, never automatic suppression."""

import copy
import importlib.util
import json
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("infrastructure_plan_comparison", Path(__file__).with_name("infrastructure_plan_comparison.py"))
COMPARISON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPARISON)
COMMIT = "a" * 40
APPLIED = "b" * 40
PREFIX = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/ipaffs-test/providers/"


def field(path="properties.ipVersionType", action="Delete", before="[withheld]", after="[withheld]", **extra):
    return {"path": path, "changeType": action, "before": before, "after": after,
            "unresolved": False, "metadataOnly": False, **extra}


def resource(resource_type="Microsoft.Network/privateEndpoints", name="endpoint", action="Modify", fields=None, **extra):
    return {"resourceId": PREFIX + resource_type + "/" + name, "type": resource_type, "name": name,
            "changeType": action, "fields": [field()] if fields is None else fields,
            "potential": False, "category": "resource", "metadataOnly": False, "unresolved": False, **extra}


def report(environment="DEV", resources=None, component="infra"):
    components = [{"name": name, "status": "complete", "diagnosticCount": 0,
                   "resources": list(resources or []) if name == component else []}
                  for name in sorted(COMPARISON.COMPONENTS)]
    return {"schemaVersion": 1, "kind": "environment", "executionStatus": "succeeded",
            "metadata": {"environment": environment, "commit": COMMIT, "buildId": "42",
                         "generatedAt": "2026-11-04T10:05:00Z" if environment == "DEV" else "2026-11-04T10:20:00Z"}, "components": components}


def evidence(**extra):
    return {"schemaVersion": 1, "status": "usable", "reasonCode": "VERIFIED", "appliedCommit": APPLIED,
            "appliedBuildId": 41, "appliedPipelineId": 9217, "previewCommit": COMMIT,
            "previewBuildId": "42", "deploymentInputsUnchanged": True, "sourceVerified": True,
            "sourceDeploymentVerified": True, "sourceDeploymentStages": COMPARISON.SOURCE_DEPLOYMENT_STAGES,
            "appliedBranch": "refs/heads/main", "comparedPaths": COMPARISON.COMPARED_PATHS,
            "verifiedAt": "2026-11-04T10:10:00Z", "appliedFinishTime": "2026-11-04T10:00:00Z", **extra}


class InfrastructurePlanComparisonTests(unittest.TestCase):
    def compare(self, dev=None, target=None, proof=None):
        return COMPARISON.analyze_comparison(report(resources=[resource()]) if dev is None else dev,
            report("TST", [resource(name="other-environment")]) if target is None else target,
            evidence() if proof is None else proof)

    def test_recurring_known_omitted_default_is_only_potential_noise(self):
        result = self.compare()
        self.assertEqual("usable", result["baseline"]["status"])
        self.assertEqual(1, result["counts"]["potentialNoiseResources"])
        item = result["resources"][0]
        self.assertEqual("potential-noise", item["classification"])
        self.assertEqual("pattern-only", item["fields"][0]["confidence"])
        self.assertNotIn("before", item["fields"][0])
        self.assertNotIn("after", item["fields"][0])

    def test_component_type_property_and_operation_must_match(self):
        cases = [report(resources=[resource()], component="acr"),
                 report(resources=[resource("Microsoft.Network/privateLinkServices")]),
                 report(resources=[resource(fields=[field("properties.ipVersion")])]),
                 report(resources=[resource(fields=[field(action="Modify")])])]
        for dev in cases:
            with self.subTest(dev=dev):
                self.assertEqual(0, self.compare(dev=dev)["counts"]["potentialNoiseResources"])

    def test_public_value_differences_veto_pattern_matches(self):
        dev = report(resources=[resource("Microsoft.OperationalInsights/workspaces", fields=[field("properties.retentionInDays", before=30)])])
        for target_before in (90, "[withheld]", True):
            target = report("PRE", [resource("Microsoft.OperationalInsights/workspaces", fields=[field("properties.retentionInDays", before=target_before)])])
            with self.subTest(target_before=target_before):
                self.assertEqual(0, self.compare(dev, target)["counts"]["potentialNoiseFields"])

    def test_matching_public_values_are_evidence_not_proven_false(self):
        config = resource("Microsoft.OperationalInsights/workspaces", fields=[field("properties.retentionInDays", before=30, after=0)])
        result = self.compare(report(resources=[config]), report("PRE", [config]))
        self.assertEqual("potential-noise", result["resources"][0]["classification"])
        self.assertEqual("matching-values", result["resources"][0]["fields"][0]["confidence"])

    def test_redacted_arbitrary_properties_cannot_establish_matches(self):
        resources = [resource(fields=[field("properties.customSetting", action="Modify")])]
        result = self.compare(report(resources=resources), report("TST", resources))
        self.assertEqual(0, result["counts"]["potentialNoiseFields"])
        self.assertEqual("review-needed", result["resources"][0]["classification"])

    def test_both_missing_sides_are_never_matching_value_evidence(self):
        default = resource(fields=[field(before="[not present]", after="[not present]")])
        result = self.compare(report(resources=[default]), report("TST", [default]))
        self.assertEqual("pattern-only", result["resources"][0]["fields"][0]["confidence"])

    def test_real_version_cidr_sku_sql_and_subnet_edits_stay_for_review(self):
        for path in ("properties.kubernetesVersion", "properties.networkProfile.podCidr", "sku.size",
                     "properties.subnets.0.properties.addressPrefix", "properties.members.0.databaseName", "properties.script"):
            with self.subTest(path=path):
                resources = [resource("Microsoft.ContainerService/managedClusters", fields=[field(path, "Modify", "old", "new")])]
                result = self.compare(report(resources=resources), report("PRD", resources))
                self.assertEqual("review-needed", result["resources"][0]["classification"])
                self.assertEqual(0, result["counts"]["potentialNoiseFields"])

    def test_mixed_noise_and_config_resource_keeps_config_review(self):
        config = resource(fields=[field(), field("properties.subnet.id", "Modify")])
        result = self.compare(report(resources=[config]), report("TST", [config]))
        self.assertEqual(1, result["counts"]["reviewResources"])
        self.assertEqual(1, result["counts"]["potentialNoiseFields"])
        self.assertEqual(1, result["counts"]["reviewFields"])

    def test_security_and_policy_rules_always_need_ownership_review(self):
        resources = [resource("Microsoft.Network/networkSecurityGroups", fields=[field("properties.securityRules.3")]),
                     resource("Microsoft.Search/searchServices", fields=[field("properties.disableLocalAuth", before=False)]),
                     resource("Microsoft.ContainerRegistry/registries", fields=[field("properties.encryption")])]
        result = self.compare(report(resources=resources), report("PRD", resources))
        self.assertEqual(3, result["counts"]["policySecurityResources"])
        self.assertEqual(0, result["counts"]["potentialNoiseFields"])

    def test_generated_identity_fields_have_a_specific_readonly_exception(self):
        default = resource("Microsoft.ManagedIdentity/userAssignedIdentities", fields=[field("properties")])
        result = self.compare(report(resources=[default]), report("TST", [default]))
        self.assertEqual(1, result["counts"]["potentialNoiseResources"])
        authorization = resource("Microsoft.Authorization/roleAssignments", fields=[field("properties.principalId")])
        result = self.compare(report(resources=[authorization]), report("TST", [authorization]))
        self.assertEqual(1, result["counts"]["policySecurityResources"])

    def test_classic_snd_is_not_an_equivalent_target_environment(self):
        default = resource("Microsoft.ManagedIdentity/userAssignedIdentities", fields=[field("properties")])
        result = self.compare(report(resources=[default], component="classic"), report("TST", [default], "classic"))
        self.assertEqual("CLASSIC_SCOPE_DIFFERS", result["resources"][0]["fields"][0]["reasonCode"])
        self.assertEqual(0, result["counts"]["potentialNoiseFields"])

    def test_array_indexes_are_not_generalised_or_matched(self):
        for path in ("properties.agentPoolProfiles.0.count", "properties.ipConfigurations[0].id", "properties.retentionInDays.0"):
            with self.subTest(path=path):
                item = resource("Microsoft.OperationalInsights/workspaces", fields=[field(path)])
                result = self.compare(report(resources=[item]), report("TST", [item]))
                self.assertEqual(0, result["counts"]["potentialNoiseFields"])

    def test_creates_deletes_and_potential_actions_are_not_noise(self):
        targets = [resource(action="Create"), resource(action="Delete"), resource(potential=True)]
        result = self.compare(target=report("TST", targets))
        self.assertEqual(0, result["counts"]["potentialNoiseResources"])
        self.assertEqual(2, result["counts"]["reviewResources"])
        self.assertEqual(1, result["counts"]["unresolvedResources"])

    def test_no_effect_and_created_date_are_background_not_baseline_matches(self):
        items = [resource(fields=[field(action="NoEffect")]),
                 resource(fields=[field("tags.CreatedDate", "Modify", metadataOnly=True)], metadataOnly=True)]
        result = self.compare(target=report("TST", items))
        self.assertEqual(2, result["counts"]["backgroundResources"])
        self.assertEqual(0, result["counts"]["potentialNoiseResources"])

    def test_unknown_unsupported_and_unresolved_values_are_coverage_gaps(self):
        targets = [resource(action=action) for action in ("Unsupported", "Unknown", "Deploy")]
        targets.append(resource(fields=[field(after="[unresolved expression]", unresolved=True)], unresolved=True))
        result = self.compare(target=report("TST", targets))
        self.assertEqual(4, result["counts"]["unresolvedResources"])
        self.assertEqual(0, result["counts"]["potentialNoiseFields"])

    def test_every_dev_component_must_execute_without_diagnostics(self):
        for mutate in (lambda dev: dev["components"].pop(),
                       lambda dev: dev["components"][0].update(status="failed"),
                       lambda dev: dev["components"][0].update(diagnosticCount=1),
                       lambda dev: dev.update(executionStatus="failed")):
            dev = report(resources=[resource()])
            mutate(dev)
            with self.subTest(dev=dev):
                result = self.compare(dev=dev)
                self.assertEqual("DEV_EXECUTION_INCOMPLETE", result["baseline"]["reasonCode"])
                self.assertEqual(0, result["counts"]["potentialNoiseResources"])

    def test_dev_control_resource_actions_invalidate_the_control(self):
        for control in (resource(action="Create"), resource(action="Delete"), resource(potential=True)):
            with self.subTest(control=control):
                result = self.compare(dev=report(resources=[control]))
                self.assertEqual("DEV_CONTROL_HAS_ACTIONS", result["baseline"]["reasonCode"])

    def test_timestamped_deployment_wrappers_are_not_resource_creates(self):
        for action in ("Create", "Delete"):
            with self.subTest(action=action):
                wrapper = resource("Microsoft.Resources/deployments", action=action, category="deployment-metadata")
                result = self.compare(dev=report(resources=[wrapper, resource()]))
                self.assertEqual("usable", result["baseline"]["status"])
                self.assertEqual(1, result["counts"]["potentialNoiseResources"])
        wrapper["potential"] = True
        self.assertEqual("DEV_CONTROL_HAS_ACTIONS", self.compare(dev=report(resources=[wrapper]))["baseline"]["reasonCode"])

    def test_forged_deployment_wrapper_category_cannot_bypass_control_action_check(self):
        control = resource(action="Create", category="deployment-metadata")
        self.assertEqual("DEV_CONTROL_HAS_ACTIONS", self.compare(dev=report(resources=[control]))["baseline"]["reasonCode"])

    def test_missing_unverified_and_changed_source_evidence_disable_matching(self):
        for proof in ({}, evidence(status="unusable"), evidence(sourceVerified=False),
                      evidence(deploymentInputsUnchanged=False), evidence(appliedPipelineId=5),
                      evidence(appliedBuildId=0), evidence(appliedBranch="refs/heads/other"),
                      evidence(appliedCommit="bad"), evidence(comparedPaths=["bicep"]),
                      evidence(sourceDeploymentVerified=False), evidence(sourceDeploymentVerified=None),
                      evidence(sourceDeploymentStages=COMPARISON.SOURCE_DEPLOYMENT_STAGES[:-1])):
            with self.subTest(proof=proof):
                result = self.compare(proof=proof)
                self.assertEqual("unavailable", result["baseline"]["status"])
                self.assertEqual(1, result["counts"]["reviewResources"])

    def test_changed_deployment_inputs_explain_why_control_is_unavailable(self):
        result = self.compare(proof=evidence(status="unusable", reasonCode="DEPLOYMENT_INPUTS_CHANGED"))
        self.assertEqual("DEPLOYMENT_INPUTS_CHANGED", result["baseline"]["reasonCode"])
        self.assertEqual("unavailable", result["baseline"]["status"])
        self.assertEqual(0, result["counts"]["potentialNoiseResources"])

    def test_input_provenance_protects_deployment_entrypoint_and_all_parameter_mappings(self):
        self.assertIn("pipelines/infrastructure.yaml", COMPARISON.COMPARED_PATHS)
        for name in ("resource-group", "network", "acr", "classic", "infra", "privatelink"):
            self.assertIn("pipelines/stages/deploy-bicep-" + name + ".yaml", COMPARISON.COMPARED_PATHS)
        for path in COMPARISON.COMPARED_PATHS:
            with self.subTest(missing_path=path):
                proof = evidence(comparedPaths=[item for item in COMPARISON.COMPARED_PATHS if item != path])
                self.assertEqual("unavailable", self.compare(proof=proof)["baseline"]["status"])

    def test_every_successful_source_deployment_stage_must_be_attested(self):
        for stage in COMPARISON.SOURCE_DEPLOYMENT_STAGES:
            with self.subTest(stage=stage):
                proof = evidence(sourceDeploymentStages=[item for item in COMPARISON.SOURCE_DEPLOYMENT_STAGES if item != stage])
                self.assertEqual("APPLIED_SOURCE_NOT_VERIFIED", self.compare(proof=proof)["baseline"]["reasonCode"])
        proof = evidence(sourceDeploymentStages=[*COMPARISON.SOURCE_DEPLOYMENT_STAGES, "OtherStage"])
        self.assertEqual("unavailable", self.compare(proof=proof)["baseline"]["status"])

    def test_retired_bridge_cannot_establish_a_current_control_or_target(self):
        self.assertEqual(6, len(COMPARISON.COMPONENTS))
        self.assertEqual(6, len(COMPARISON.SOURCE_DEPLOYMENT_STAGES))
        self.assertEqual(11, len(COMPARISON.COMPARED_PATHS))
        self.assertIn("scripts/pipeline/ensure-bicep-version.sh", COMPARISON.COMPARED_PATHS)
        bridge = {"name": "infra-to-classic", "status": "complete", "diagnosticCount": 0, "resources": []}
        dev = report(resources=[resource()])
        dev["components"].append(bridge)
        self.assertEqual("DEV_EXECUTION_INCOMPLETE", self.compare(dev=dev)["baseline"]["reasonCode"])
        target = report("TST", [resource()])
        target["components"].append(bridge)
        self.assertEqual("TARGET_REPORT_INVALID", self.compare(target=target)["baseline"]["reasonCode"])
        proof = evidence(sourceDeploymentStages=[*COMPARISON.SOURCE_DEPLOYMENT_STAGES, "DeployInfrastructureToClassic"])
        self.assertEqual("APPLIED_SOURCE_NOT_VERIFIED", self.compare(proof=proof)["baseline"]["reasonCode"])

    def test_stale_build_or_candidate_report_cannot_be_used(self):
        for change in ({"buildId": "43"}, {"commit": "c" * 40}):
            for which in ("dev", "target"):
                dev, target = report(resources=[resource()]), report("TST", [resource()])
                (dev if which == "dev" else target)["metadata"].update(change)
                result = self.compare(dev, target)
                self.assertEqual("BASELINE_CANDIDATE_MISMATCH", result["baseline"]["reasonCode"])

    def test_apply_must_finish_before_source_verification_and_preview(self):
        for proof in (evidence(appliedFinishTime="2026-11-04T11:00:00Z"),
                      evidence(verifiedAt="2026-11-04T11:00:00Z"), evidence(verifiedAt="bad")):
            with self.subTest(proof=proof):
                result = self.compare(proof=proof)
                self.assertEqual("BASELINE_TIMING_INVALID", result["baseline"]["reasonCode"])

    def test_provenance_must_be_checked_promptly_after_dev_initialisation(self):
        proof = evidence(verifiedAt="2026-11-04T10:10:01Z")
        self.assertEqual("BASELINE_TIMING_INVALID", self.compare(proof=proof)["baseline"]["reasonCode"])
        proof = evidence(verifiedAt="2026-11-04T10:04:59Z")
        self.assertEqual("BASELINE_TIMING_INVALID", self.compare(proof=proof)["baseline"]["reasonCode"])

    def test_concurrent_target_initialisation_can_precede_dev_and_its_verification(self):
        for generated in ("2026-11-04T10:00:00Z", "2026-11-04T10:04:00Z",
                          "2026-11-04T10:05:00Z", "2026-11-04T10:07:00Z", "2026-11-04T10:20:00Z"):
            for environment in ("TST", "PRE", "PRD"):
                with self.subTest(generated=generated, environment=environment):
                    target = report(environment, [resource()])
                    target["metadata"]["generatedAt"] = generated
                    result = self.compare(target=target)
                    self.assertEqual("usable", result["baseline"]["status"])
                    self.assertEqual(1, result["counts"]["potentialNoiseResources"])

    def test_concurrent_target_must_still_start_after_source_apply(self):
        target = report("TST", [resource()])
        target["metadata"]["generatedAt"] = "2026-11-04T09:59:59Z"
        result = self.compare(target=target)
        self.assertEqual("BASELINE_TIMING_INVALID", result["baseline"]["reasonCode"])
        self.assertEqual(0, result["counts"]["potentialNoiseResources"])

    def test_malformed_or_timezone_free_timestamps_fail_closed(self):
        for invalid in (None, [], "bad", "2026-11-04T10:05:00", "2026-99-04T10:05:00Z",
                        "2026-11-04T10:05:00.1234567890Z", "2026-11-04T10:05:00.Z",
                        "2026-11-04T10:05:00+99:00", "2026-11-04T10:05:00Zjunk"):
            for location in ("dev", "target", "verifiedAt", "appliedFinishTime"):
                with self.subTest(invalid=invalid, location=location):
                    dev, target, proof = report(resources=[resource()]), report("TST", [resource()]), evidence()
                    if location in {"dev", "target"}:
                        (dev if location == "dev" else target)["metadata"]["generatedAt"] = invalid
                    else:
                        proof[location] = invalid
                    result = self.compare(dev, target, proof)
                    self.assertEqual("BASELINE_TIMING_INVALID", result["baseline"]["reasonCode"])

    def test_actual_azure_seven_digit_finish_timestamp_is_compatible_with_agent_python(self):
        proof = evidence(appliedFinishTime="2026-11-04T09:52:18.2173814Z")
        result = self.compare(proof=proof)
        self.assertEqual("usable", result["baseline"]["status"])
        self.assertEqual(1, result["counts"]["potentialNoiseResources"])
        parsed = COMPARISON._time(proof["appliedFinishTime"])
        self.assertEqual(217381, parsed.microsecond)
        self.assertEqual(0, parsed.utcoffset().total_seconds())

    def test_fraction_normalisation_retains_offsets_and_apply_ordering_guards(self):
        for fraction in ("1", "12", "123", "1234", "12345", "123456", "1234567", "123456789"):
            with self.subTest(fraction=fraction):
                timestamp = "2026-11-04T11:00:00." + fraction + "+01:00"
                parsed = COMPARISON._time(timestamp)
                self.assertEqual(3600, parsed.utcoffset().total_seconds())
                self.assertEqual(int(fraction[:6].ljust(6, "0")), parsed.microsecond)
                proof = evidence(appliedFinishTime=timestamp)
                self.assertEqual("usable", self.compare(proof=proof)["baseline"]["status"])
        proof = evidence(appliedFinishTime="2026-11-04T10:05:00.0000010Z")
        self.assertEqual("BASELINE_TIMING_INVALID", self.compare(proof=proof)["baseline"]["reasonCode"])

    def test_extension_resource_preserves_parent_scope_and_final_provider_type(self):
        item = resource("Microsoft.Authorization/roleAssignments", name="role")
        item["resourceId"] = PREFIX + "Microsoft.Sql/servers/sql-server/providers/Microsoft.Authorization/roleAssignments/role"
        result = self.compare(target=report("TST", [item]))
        output = result["resources"][0]
        self.assertEqual(item["resourceId"], output["resourceId"])
        self.assertEqual("Microsoft.Authorization/roleAssignments", output["type"])
        self.assertEqual("policy-security-review", output["classification"])

    def test_unsupported_entries_retain_known_types_without_inventing_identity(self):
        for kind in ("Microsoft.Authorization/roleAssignments",
                     "Microsoft.Search/searchServices/sharedPrivateLinkResources"):
            for identifier in (None, "unavailable", "[unresolved expression]", [], {}, "invalid-resource-id"):
                with self.subTest(kind=kind, identifier=identifier):
                    item = resource(kind, action="Unsupported", fields=[])
                    item.update(resourceId=identifier, name="must-not-be-forwarded")
                    result = self.compare(target=report("TST", [item]))
                    output = result["resources"][0]
                    self.assertEqual(kind.lower(), output["type"])
                    self.assertEqual("unavailable", output["resourceId"])
                    self.assertEqual("unavailable", output["name"])
                    self.assertEqual("unresolved-coverage", output["classification"])
                    self.assertEqual("ACTION_NOT_ASSESSED", output["reasonCode"])
                    self.assertEqual(1, result["counts"]["unresolvedResources"])
                    self.assertEqual(0, result["counts"]["potentialNoiseResources"])

    def test_every_catalog_fallback_remains_an_unresolved_observation(self):
        from infrastructure_plan_markdown import TYPE_LABELS

        for kind in TYPE_LABELS:
            with self.subTest(kind=kind):
                item = resource(kind.upper(), action="Unsupported", fields=[])
                item["resourceId"] = "unavailable"
                result = self.compare(target=report("PRE", [item]))
                self.assertEqual(kind, result["resources"][0]["type"])
                self.assertEqual("unresolved-coverage", result["resources"][0]["classification"])
                self.assertEqual(0, result["counts"]["backgroundResources"])

    def test_type_fallback_cannot_resolve_actions_or_potential_entries(self):
        for action in ("Create", "Modify", "Delete", "NoChange", "Ignore", "Deploy", "Unknown"):
            with self.subTest(action=action):
                item = resource("Microsoft.ManagedIdentity/userAssignedIdentities", action=action)
                item["resourceId"] = "unavailable"
                result = self.compare(target=report("TST", [item]))
                self.assertEqual("unavailable", result["resources"][0]["type"])
                self.assertEqual(0, result["counts"]["potentialNoiseResources"])
        for potential in (True, None, [], {}, "false"):
            with self.subTest(potential=potential):
                item = resource("Microsoft.Authorization/roleAssignments", action="Unsupported", potential=potential)
                item["resourceId"] = "unavailable"
                result = self.compare(target=report("TST", [item]))
                self.assertEqual("unavailable", result["resources"][0]["type"])
                self.assertEqual("unresolved-coverage", result["resources"][0]["classification"])

    def test_valid_but_conflicting_identifier_never_uses_claimed_type_fallback(self):
        item = resource("Microsoft.Network/privateEndpoints", action="Unsupported", fields=[])
        item["type"] = "Microsoft.Authorization/roleAssignments"
        result = self.compare(target=report("PRD", [item]))
        output = result["resources"][0]
        self.assertEqual("unavailable", output["resourceId"])
        self.assertEqual("unavailable", output["type"])
        self.assertEqual("unresolved-coverage", output["classification"])

    def test_unsupported_type_fallback_does_not_publish_arbitrary_type_strings(self):
        secret = "PASSWORD-SENSITIVE"
        for kind in (None, [], {}, True, "Microsoft.Private/" + secret,
                     "Microsoft.Authorization/roleAssignments/" + secret, "<script>" + secret):
            with self.subTest(kind=kind):
                item = resource(action="Unsupported", fields=[])
                item.update(resourceId="unavailable", type=kind, name=secret)
                result = self.compare(target=report("TST", [item]))
                self.assertEqual("unavailable", result["resources"][0]["type"])
                self.assertEqual("unresolved-coverage", result["resources"][0]["classification"])
                self.assertNotIn(secret, json.dumps(result))

    def test_unsupported_entries_with_valid_ids_keep_their_exact_resource_reference(self):
        item = resource("Microsoft.Authorization/roleAssignments", action="Unsupported", fields=[])
        output = self.compare(target=report("TST", [item]))["resources"][0]
        self.assertEqual(item["resourceId"], output["resourceId"])
        self.assertEqual(item["type"], output["type"])
        self.assertEqual(item["name"], output["name"])
        self.assertEqual("unresolved-coverage", output["classification"])

    def test_invalid_and_missing_dev_reports_fail_closed(self):
        for dev in ({}, {"schemaVersion": 1}, report("TST"), []):
            with self.subTest(dev=dev):
                result = COMPARISON.analyze_comparison(dev, report("TST", [resource()]), evidence())
                self.assertEqual("DEV_REPORT_MISSING_OR_INVALID", result["baseline"]["reasonCode"])
                self.assertEqual(0, result["counts"]["potentialNoiseResources"])

    def test_malformed_target_and_hostile_payload_are_safely_reprojected(self):
        secret = "DO-NOT-PUBLISH-THIS-PASSWORD"
        hostile = resource(fields=[field("properties['" + secret + "']", "Modify", secret, secret)])
        hostile.update(resourceId="<script>" + secret, name=secret, type=secret, arbitrary={"password": secret})
        target = report("TST", [hostile])
        target.update(diagnostics={"password": secret}, extra=secret)
        target["metadata"]["sourceRef"] = secret
        result = self.compare(target=target)
        text = json.dumps(result)
        self.assertNotIn(secret, text)
        self.assertNotIn("script", text)
        self.assertEqual("unavailable", result["resources"][0]["resourceId"])
        self.assertEqual("[unrecognised property]", result["resources"][0]["fields"][0]["path"])

    def test_lookalike_resource_type_cannot_borrow_default_classification(self):
        item = resource()
        item["type"] = "Microsoft.ManagedIdentity/userAssignedIdentities"
        item["fields"] = [field("properties")]
        result = self.compare(target=report("TST", [item]))
        self.assertEqual(0, result["counts"]["potentialNoiseResources"])
        self.assertEqual("unavailable", result["resources"][0]["type"])

    def test_malformed_artifact_containers_cannot_crash_or_supply_noise_matches(self):
        for invalid in ({"hostile": "value"}, ["hostile"], None, True):
            with self.subTest(invalid=invalid):
                item = resource()
                item["changeType"] = invalid
                target = report("TST", [item])
                target["metadata"]["environment"] = invalid
                target["components"][0]["name"] = invalid
                result = self.compare(target=target)
                self.assertEqual(0, result["counts"]["potentialNoiseResources"])
                dev = report(resources=[resource()])
                dev["components"][0]["name"] = invalid
                self.assertEqual("unavailable", self.compare(dev=dev)["baseline"]["status"])

    def test_forged_metadata_flags_cannot_hide_config_changes(self):
        item = resource(fields=[field("properties.kubernetesVersion", "Modify", metadataOnly=True)],
                        metadataOnly=True, category="deployment-metadata")
        result = self.compare(target=report("TST", [item]))
        self.assertEqual(1, result["counts"]["reviewResources"])
        self.assertEqual(0, result["counts"]["backgroundResources"])

    def test_potential_no_effect_and_inventory_entries_remain_uncertain(self):
        for item in (resource(potential=True, fields=[field(action="NoEffect")]),
                     resource(potential=True, action="Ignore")):
            with self.subTest(item=item):
                result = self.compare(target=report("TST", [item]))
                self.assertEqual(1, result["counts"]["unresolvedResources"])

    def test_failed_target_execution_disables_control_labels(self):
        target = report("TST", [resource()])
        target["executionStatus"] = "failed"
        result = self.compare(target=target)
        self.assertEqual("TARGET_EXECUTION_INCOMPLETE", result["baseline"]["reasonCode"])
        self.assertEqual(0, result["counts"]["potentialNoiseResources"])

    def test_repeated_analysis_is_deterministic_and_does_not_mutate_inputs(self):
        dev, target, proof = report(resources=[resource()]), report("TST", [resource()]), evidence()
        snapshot = copy.deepcopy((dev, target, proof))
        first = COMPARISON.analyze_comparison(dev, target, proof)
        second = COMPARISON.analyze_comparison(dev, target, proof)
        self.assertEqual(first, second)
        self.assertEqual(snapshot, (dev, target, proof))


if __name__ == "__main__":
    unittest.main()
