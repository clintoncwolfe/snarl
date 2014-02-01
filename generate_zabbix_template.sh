FILE=share/snarl_template.xml
cat <<EOF > $FILE
<?xml version="1.0" encoding="UTF-8"?>
<zabbix_export>
    <version>2.0</version>
    <date>2013-04-29T03:56:41Z</date>
    <groups>
        <group>
            <name>Templates</name>
        </group>
    </groups>
    <templates>
        <template>
            <template>FiFo Snarl</template>
            <name>FiFo Snarl</name>
            <groups>
                <group>
                    <name>Templates</name>
                </group>
            </groups>
            <applications>
                <application>
                    <name>General</name>
                </application>
            </applications>
            <items>
EOF
cat apps/snarl/include/SNARL-MIB.hrl | grep instance | sed 's/-define(//' | sed 's/_instance, ./ /' | sed 's/]).//' | sed 's/,/./g' | while read param oid
do
    cat <<EOF >> $FILE
                <item>
                    <name>$param</name>
                    <type>4</type>
                    <snmp_community>public</snmp_community>
                    <multiplier>0</multiplier>
                    <snmp_oid>$oid</snmp_oid>
                    <key>fifo.snarl.$param</key>
                    <delay>30</delay>
                    <history>90</history>
                    <trends>365</trends>
                    <status>0</status>
                    <value_type>3</value_type>
                    <allowed_hosts/>
EOF
    if echo $param | grep Count
    then
        cat <<EOF >> $FILE
                    <units>requests</units>
                    <formula>1</formula>
EOF
    else
        cat <<EOF >> $FILE
                    <units>nanoseconds</units>
                    <formula>0.001</formula>
EOF
    fi

    cat <<EOF >> $FILE

                    <delta>0</delta>
                    <snmpv3_securityname/>
                    <snmpv3_securitylevel>0</snmpv3_securitylevel>
                    <snmpv3_authpassphrase/>
                    <snmpv3_privpassphrase/>
                    <delay_flex/>
                    <params/>
                    <ipmi_sensor/>
                    <data_type>0</data_type>
                    <authtype>0</authtype>
                    <username/>
                    <password/>
                    <publickey/>
                    <privatekey/>
                    <port/>
                    <description/>
                    <inventory_link>0</inventory_link>
                    <applications/>
                    <valuemap/>
                </item>
EOF
done
cat <<EOF >> $FILE
            </items>
            <discovery_rules/>
            <macros/>
            <templates/>
            <screens/>
        </template>
    </templates>
</zabbix_export>
EOF
