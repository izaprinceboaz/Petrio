import { useEffect, useState } from "react";
import supabase from "../../lib/supabaseClient";

export default function Account() {
    const [fetchError, setFetchError] = useState<string | null>(null);
    const [table, setTable] = useState<any[] | null>(null);

    useEffect(() => {
        const fetchSmoothies = async () => {
            const { data, error } = await supabase
                .from('audit_log')
                .select('*');
            console.log(data);
            

            if (error) {
                setFetchError(error.message);
                setTable(null);
            }

            if (data) {
                setTable(data);
                setFetchError(null);
            }
        };

        fetchSmoothies(); // 1. Execute the async function
    }, []); // 2. Empty dependency array ensures this runs ONCE when the component mounts

    return (
        <div>
            <h2>Account Page</h2>
            
            {fetchError && <p className="error">{fetchError}</p>}
            
            {table && (
                <div>
                    {table.map((item) => (
                        <div key={item.id}>
                            {/* Render your data fields here, e.g., item.title */}
                            <pre>{JSON.stringify(item, null, 2)}</pre>
                        </div>
                    ))}
                </div>
            )}
        </div>
    );
}