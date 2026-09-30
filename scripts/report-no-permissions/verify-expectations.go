//go:build ignore

// Oracle for the EXPECT column in lab.sh. Runs each scenario's RBAC config through the same call the
// API server makes, so the table cannot drift away from the implementation.
//
//	go run scripts/report-no-permissions/verify-expectations.go
package main

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"

	"github.com/argoproj/argo-cd/v3/common"
	argoappv1 "github.com/argoproj/argo-cd/v3/pkg/apis/application/v1alpha1"
	"github.com/argoproj/argo-cd/v3/server/rbacpolicy"
	"github.com/argoproj/argo-cd/v3/test"
	"github.com/argoproj/argo-cd/v3/util/assets"
	"github.com/argoproj/argo-cd/v3/util/rbac"
)

const (
	user     = "alice"
	project  = "lab-demo"
	allow    = "p, alice, applications, get, */*, allow"
	anchored = "p, alice, applications, get, ^default/.*$, allow"
)

type scenario struct {
	n           int
	reportOff   bool
	mode        string
	defaultRole string
	policy      string
	projPolicy  string
}

func main() {
	for _, s := range []scenario{
		{n: 1, reportOff: true},
		{n: 2},
		{n: 3, policy: allow},
		{n: 4, policy: allow + "\np, alice, *, *, *, deny"},
		{n: 5, policy: allow + "\np, alice, clusters, get, *, deny"},
		{n: 6, policy: "g, alice, role:viewer\np, role:viewer, applications, get, */*, allow"},
		{n: 7, policy: "g, alice, role:viewer\np, role:viewer, applications, get, */*, allow\np, alice, *, *, *, deny"},
		{n: 8, policy: "p, alice, applications, get, default/app-[a-z]*, allow"},
		{n: 9, mode: rbac.RegexMatchMode, policy: anchored},
		{n: 10, mode: rbac.RegexMatchMode, policy: anchored + "\np, alice, ^$, ^$, ^$, deny"},
		{n: 11, mode: rbac.RegexMatchMode, policy: anchored + "\np, alice, .*, .*, .*, deny"},
		{n: 12, defaultRole: "role:readonly"},
		{n: 13, projPolicy: "p, proj:" + project + ":dev, applications, sync, " + project + "/*, allow"},
		{n: 14, policy: "p, alice, *, *, *, deny", projPolicy: "p, proj:" + project + ":dev, applications, sync, " + project + "/*, allow"},
		{n: 15, projPolicy: "p, proj:" + project + ":dev, applications, sync, " + project + "/*, deny"},
	} {
		fmt.Printf("%d %s\n", s.n, verdict(s))
	}
}

func verdict(s scenario) string {
	// With the setting off the server never looks, so nothing is ever reported.
	if s.reportOff {
		return "SILENT"
	}
	enf := rbac.NewEnforcer(fake.NewClientset(test.NewFakeConfigMap()), test.FakeArgoCDNamespace, common.ArgoCDConfigMapName, nil)
	if err := enf.SetBuiltinPolicy(assets.BuiltinPolicyCSV); err != nil {
		panic(err)
	}
	enf.SetMatchMode(s.mode)
	enf.SetDefaultRole(s.defaultRole)
	if err := enf.SetUserPolicy(s.policy); err != nil {
		panic(err)
	}

	lister := test.NewFakeProjLister()
	if s.projPolicy != "" {
		lister = test.NewFakeProjLister(&argoappv1.AppProject{
			ObjectMeta: metav1.ObjectMeta{Name: project, Namespace: test.FakeArgoCDNamespace},
			Spec: argoappv1.AppProjectSpec{Roles: []argoappv1.ProjectRole{{
				Name: "dev", Policies: []string{s.projPolicy}, Groups: []string{user},
			}}},
		})
	}

	// A local session carries no groups, which is what Session.GetUserInfo passes.
	if rbacpolicy.NewRBACPolicyEnforcer(enf, lister).HasAnyPermission(user, nil) {
		return "SILENT"
	}
	return "REPORTED"
}
