## helper_scripts/install_rhwa_operators

This script help you to install rhwa operators on a ocp cluster ( Tested on Clusterbot, BM and Hyperhsift Cluster ) and the best part about the same is that it will auto create a IDMS from given catalog source.

It has a bunch of methods how to use the same and the script is quit flexible with a lot of options adding the help section below:

```
vipikuma@kvy:~/rhwa$ sh scripts/install_rhwa_operators.sh --help
################################################################################
Install all 5 RHWA operators: NHC, SNR, NMO, MDR, FAR.

Options:
  --channel CHANNEL     Subscription channel (default: stable)
  --catsrc NAME         CatalogSource name (default: redhat-operators)
  --catsrc-ns NS        CatalogSource namespace (default: openshift-marketplace)
  --namespace NS        Install operators into NS (default: openshift-workload-availability)
  --disable-nhc-plugin   Do not enable NHC console plugin (enabled by default)
  --approval MANUAL|AUTO InstallPlan approval (default: Automatic)
  --only LIST           Install only these operators (comma-separated: nhc,snr,nmo,mdr,far). Default: all.
  --create-idms         Wait for --catsrc to be READY, generate IDMS from latest catalog versions, apply it, then install
  --wait                Wait for all CSVs to succeed (default: true)
  --kubeconfig-from HOST (optional) Download kubeconfig from remote host via SSH (user: root).
                         Exports KUBECONFIG for this run.
  --kubeconfig-path PATH (optional) Remote path to kubeconfig when using --kubeconfig-from (default: /root/.kube/config).
#
Environment:
  NHC_CONSOLE_PLUGIN_NAME  ConsolePlugin.metadata.name (default: node-remediation-console-plugin)
  NHC_CONSOLE_PLUGIN_WAIT  Seconds to wait for that CR after CSV install (default: 300)
#

  Defaults: channel=stable, catsrc=redhat-operators, namespace=openshift-workload-availability, approval=Automatic, nhc-plugin=enabled
  --create-idms: wait for catalog READY, write <script-dir>/idms/imageDigestMirrorSet_<catsrc>.yaml, oc apply, then install
```

### Prerequisites:

A working OCP cluster either from Cluster bot or running on your BM.

A system from where you will be running the script ( Mostly Your Laptop ) with packages `oc, yq, jq` on the same.

And the script `helper_scripts/install_rhwa_operators.sh` you can either clone the repo or can just download the script.

* A Clusterbot cluster :
    It's a cluster we request from the slack clusterbot it give you a OCP cluster for around 2-3 Hr so either you can login to cluster and copy the login command and then login to the cluster from your terminal or you can download the kubeconfig file and export that for login.

* A BM cluster:
    These are mostly the QE lab systems reserved for testing and QE uses Jenkins jobs to setup OCP cluster on the same and then download the kubeconfig file or provide the oc login command from the GUI.


Once we have a working OCP cluster and you login to your system ( Your Laptop ) You can run the script `./helper_scripts/install_rhwa_operators.sh` 

* By default it will use channel=stable, catsrc=redhat-operators, namespace=openshift-workload-availability, approval=Automatic and nhc-plugin=enabled

Which will install all operators from the `redhat-operators` catalog source and from `stable` channel in namespace `openshift-workload-availability` it will create a workspace it wasn't there and enable the NHC Console Plugin.

* we can use different flags to use our custom values let's say I want to use my own catalog source where I have the latest IIB `latest-iib` I can use the flag `--catsrc latest-iib` and it will install operators from `latest-iib` catalog source from stable channel if we have our catalog source in some other namespace we can use the flag `--catsrc-ns` ( By default it will look for the same in namespace `openshift-marketplace` ).

* if you want to change the channel you can use flag `--channel` ex: `--channel ITN-2026-00040-stable`.

* If you do not want to enable the NHC console plugin you can use flag `--disable-nhc-plugin`.

* If you want to use some another namespace you can use the flag `--namespace`.

* There is one more useful flag `--only` let's say I want to install only 1,2 operators I can use `--only` flag for the same. Let's say I just want to install NHC and FAR only I can do something like `--only nhc,far`.

* Now the best part about the idms while testing from internal IIB's we have to create idms to map Red Hat registry with Quay images so if you use `--create-idms` option it will use the latest version from given IIB and create a IDMS also for us.

* Now for QE lab systems there is one more good option so that you do not have to do oc login you can use flag `--kubeconfig-from root@<your_system_hostname>` it will use `--kubeconfig-path` flag to find the kubeconfig on given host and install operators on the same.

For more on the same check the Usage section in the script.