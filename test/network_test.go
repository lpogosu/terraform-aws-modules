// Package test holds the integration tests for the module library.
//
// These tests create real AWS resources in whatever account the ambient credentials point
// at, and they cost real money: each run brings up a VPC with NAT gateways and tears it
// down again. There is no offline mode - `terraform plan` against the AWS provider still
// needs credentials to configure the provider - so `go vet ./...` is what CI runs, and
// `make test` is what a human runs against a sandbox account.
package test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/aws"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	minimalExample = "../examples/minimal"
	testRegion     = "eu-central-1"
	testCIDR       = "10.99.0.0/16"
)

// options builds a terraform.Options for the minimal example with a name nobody else in
// the account is using, so two runs of the suite in parallel do not collide on the
// CloudWatch log group name or the IAM role name.
func options(t *testing.T, name string, azs []string, singleNAT bool) *terraform.Options {
	return terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: minimalExample,
		Vars: map[string]interface{}{
			"region":             testRegion,
			"name":               name,
			"cidr_block":         testCIDR,
			"azs":                azs,
			"single_nat_gateway": singleNAT,
			"tags": map[string]string{
				"managed-by": "terraform",
				"purpose":    "terratest",
			},
		},
		EnvVars: map[string]string{
			"AWS_DEFAULT_REGION": testRegion,
		},
		NoColor: true,
	})
}

// TestNetworkSingleNATGateway checks the cost-saving path: one NAT gateway serving the
// private subnets of every availability zone.
func TestNetworkSingleNATGateway(t *testing.T) {
	t.Parallel()

	name := fmt.Sprintf("tt-%s", strings.ToLower(random.UniqueId()))
	azs := []string{testRegion + "a", testRegion + "b"}

	opts := options(t, name, azs, true)
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	natIPs := terraform.OutputMap(t, opts, "nat_public_ips")
	require.Len(t, natIPs, 1, "single_nat_gateway must produce exactly one gateway for the whole VPC")
	assert.Contains(t, natIPs, azs[0], "the single gateway belongs in the first availability zone")

	public := terraform.OutputList(t, opts, "public_subnet_ids")
	private := terraform.OutputList(t, opts, "private_subnet_ids")
	intra := terraform.OutputList(t, opts, "intra_subnet_ids")

	require.Len(t, public, len(azs))
	require.Len(t, private, len(azs))
	require.Len(t, intra, len(azs))

	// Both private subnets route through the one gateway, so neither is reachable from the
	// internet even though the VPC has an internet gateway attached.
	for _, id := range private {
		assert.False(t, aws.IsPublicSubnet(t, id, testRegion),
			"private subnet %s must not have a route to the internet gateway", id)
	}
}

// TestNetworkNATGatewayPerAZ checks the production path: a gateway in every availability
// zone, so losing one zone does not take egress from the others with it.
func TestNetworkNATGatewayPerAZ(t *testing.T) {
	t.Parallel()

	name := fmt.Sprintf("tt-%s", strings.ToLower(random.UniqueId()))
	azs := []string{testRegion + "a", testRegion + "b"}

	opts := options(t, name, azs, false)
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	natIPs := terraform.OutputMap(t, opts, "nat_public_ips")
	require.Len(t, natIPs, len(azs), "one NAT gateway per availability zone")
	for _, az := range azs {
		assert.Contains(t, natIPs, az)
	}

	// Every gateway gets its own Elastic IP. A duplicate would mean two zones sharing one
	// egress address, which is the failure mode this configuration exists to avoid.
	seen := make(map[string]string, len(natIPs))
	for az, ip := range natIPs {
		assert.NotContains(t, seen, ip, "availability zones %s and %s share an egress address", seen[ip], az)
		seen[ip] = az
	}
}

// TestNetworkSubnetTiers checks the property that separates an intra subnet from a private
// one: no default route at all, in either direction.
func TestNetworkSubnetTiers(t *testing.T) {
	t.Parallel()

	name := fmt.Sprintf("tt-%s", strings.ToLower(random.UniqueId()))
	azs := []string{testRegion + "a", testRegion + "b"}

	opts := options(t, name, azs, true)
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	vpcID := terraform.Output(t, opts, "vpc_id")
	require.NotEmpty(t, vpcID)

	subnets := aws.GetSubnetsForVpc(t, vpcID, testRegion)
	assert.Len(t, subnets, 3*len(azs), "three tiers in each availability zone")

	for _, id := range terraform.OutputList(t, opts, "public_subnet_ids") {
		assert.True(t, aws.IsPublicSubnet(t, id, testRegion),
			"public subnet %s must route 0.0.0.0/0 at the internet gateway", id)
	}

	for _, id := range terraform.OutputList(t, opts, "intra_subnet_ids") {
		assert.False(t, aws.IsPublicSubnet(t, id, testRegion),
			"intra subnet %s must not route to the internet gateway", id)
	}

	assert.Equal(t, fmt.Sprintf("/aws/vpc/%s/flow-logs", name),
		terraform.Output(t, opts, "flow_log_group_name"))
}
